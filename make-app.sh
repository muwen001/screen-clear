#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")" && pwd -P)
cd "$project_root"

install_requested=false
case "${1:-}" in
    "") ;;
    --install) install_requested=true ;;
    *) printf '用法: %s [--install]\n' "$0" >&2; exit 64 ;;
esac

app_name="ScreenClear.app"
bundle_id="local.screenclear"
project_app="$project_root/$app_name"
zip_path="$project_root/dist/ScreenClear-macos-arm64.zip"
install_target="/Applications/$app_name"
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-build.XXXXXX")
staged_app="$stage_root/$app_name"

cleanup() {
    if [[ -n "${stage_root:-}" && -d "$stage_root" && ! -L "$stage_root" ]]; then
        case "$stage_root" in
            */screenclear-build.*) /bin/rm -rf -- "$stage_root" ;;
            *) printf '拒绝清理意外路径: %s\n' "$stage_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

publish_project_app() {
    local previous="$stage_root/previous-project.app"

    [[ ! -L "$project_app" ]] || { printf '拒绝覆盖符号链接: %s\n' "$project_app" >&2; return 1; }
    [[ ! -e "$project_app" || -d "$project_app" ]] || {
        printf '拒绝覆盖非目录: %s\n' "$project_app" >&2
        return 1
    }

    [[ ! -d "$project_app" ]] || mv "$project_app" "$previous"
    if ! mv "$staged_app" "$project_app"; then
        [[ ! -d "$previous" ]] || mv "$previous" "$project_app"
        return 1
    fi
    if ! codesign --verify --deep --strict --verbose=2 "$project_app"; then
        mv "$project_app" "$stage_root/failed-project.app"
        [[ ! -d "$previous" ]] || mv "$previous" "$project_app"
        return 1
    fi
}

install_app() {
    local resolved_parent
    local install_backup="/Applications/.ScreenClear.backup.$$"
    local existing_id=""

    remove_new_install() {
        [[ "$install_target" = "/Applications/ScreenClear.app" ]]
        [[ -d "$install_target" && ! -L "$install_target" ]]
        /bin/rm -rf -- "$install_target"
    }

    resolved_parent=$(cd /Applications && pwd -P)
    [[ "$resolved_parent" = "/Applications" ]] || {
        printf '安装目录解析异常: %s\n' "$resolved_parent" >&2
        return 1
    }
    [[ ! -e "$install_backup" && ! -L "$install_backup" ]] || {
        printf '临时备份目标已存在: %s\n' "$install_backup" >&2
        return 1
    }
    [[ ! -L "$install_target" ]] || {
        printf '拒绝覆盖符号链接: %s\n' "$install_target" >&2
        return 1
    }
    if [[ -e "$install_target" ]]; then
        [[ -d "$install_target" ]] || {
            printf '拒绝覆盖非目录: %s\n' "$install_target" >&2
            return 1
        }
        existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$install_target/Contents/Info.plist" 2>/dev/null || true)
        [[ "$existing_id" = "$bundle_id" ]] || {
            printf '拒绝覆盖未知应用，Bundle ID=%s\n' "$existing_id" >&2
            return 1
        }
        /usr/bin/osascript -e 'tell application id "local.screenclear" to quit' \
            >/dev/null 2>&1 || true
        mv "$install_target" "$install_backup"
    fi

    if ! ditto "$project_app" "$install_target"; then
        if [[ -d "$install_target" && ! -L "$install_target" ]]; then
            remove_new_install
        fi
        [[ ! -d "$install_backup" ]] || mv "$install_backup" "$install_target"
        return 1
    fi
    if ! codesign --verify --deep --strict --verbose=2 "$install_target"; then
        if [[ -d "$install_target" && ! -L "$install_target" ]]; then
            remove_new_install
        fi
        [[ ! -d "$install_backup" ]] || mv "$install_backup" "$install_target"
        return 1
    fi
    if [[ -d "$install_backup" && ! -L "$install_backup" ]]; then
        [[ "$install_backup" = "/Applications/.ScreenClear.backup.$$" ]]
        /bin/rm -rf -- "$install_backup"
    fi
    open "$install_target"
}

swift build -c release
mkdir -p "$staged_app/Contents/MacOS"
cp .build/release/ScreenClear "$staged_app/Contents/MacOS/ScreenClear"
chmod 755 "$staged_app/Contents/MacOS/ScreenClear"
cat > "$staged_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ScreenClear</string>
    <key>CFBundleDisplayName</key><string>ScreenClear</string>
    <key>CFBundleIdentifier</key><string>local.screenclear</string>
    <key>CFBundleExecutable</key><string>ScreenClear</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$staged_app/Contents/Info.plist"
codesign --force --deep --sign - --timestamp=none "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

publish_project_app

mkdir -p "$project_root/dist"
staged_zip="$stage_root/ScreenClear-macos-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$project_app" "$staged_zip"
unzip -tq "$staged_zip"
mv -f "$staged_zip" "$zip_path"

if [[ "$install_requested" = true ]]; then
    install_app
fi

printf '✅ 生成 %s\n' "$project_app"
printf '✅ 打包 %s\n' "$zip_path"
