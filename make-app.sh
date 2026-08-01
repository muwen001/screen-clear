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
dist_dir="$project_root/dist"
zip_path="$project_root/dist/ScreenClear-macos-arm64.zip"
install_target="/Applications/$app_name"
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-build.XXXXXX")
staged_app="$stage_root/$app_name"
staged_zip="$stage_root/ScreenClear-macos-arm64.zip"
preserve_stage=false

cleanup() {
    if [[ "$preserve_stage" = true ]]; then
        printf '保留恢复暂存目录: %s\n' "$stage_root" >&2
        return
    fi
    if [[ -n "${stage_root:-}" && -d "$stage_root" && ! -L "$stage_root" ]]; then
        case "$stage_root" in
            */screenclear-build.*) /bin/rm -rf -- "$stage_root" ;;
            *) printf '拒绝清理意外路径: %s\n' "$stage_root" >&2 ;;
        esac
    fi
}
trap cleanup EXIT

validate_project_outputs() {
    local existing_id=""
    local resolved_dist

    [[ ! -L "$project_app" ]] || {
        printf '拒绝覆盖符号链接: %s\n' "$project_app" >&2
        return 1
    }
    if [[ -e "$project_app" ]]; then
        [[ -d "$project_app" ]] || {
            printf '拒绝覆盖非目录: %s\n' "$project_app" >&2
            return 1
        }
        existing_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$project_app/Contents/Info.plist" 2>/dev/null || true)
        [[ "$existing_id" = "$bundle_id" ]] || {
            printf '拒绝覆盖未知应用，Bundle ID=%s\n' "$existing_id" >&2
            return 1
        }
    fi

    [[ ! -L "$dist_dir" ]] || {
        printf '拒绝使用符号链接目录: %s\n' "$dist_dir" >&2
        return 1
    }
    [[ ! -e "$dist_dir" || -d "$dist_dir" ]] || {
        printf '拒绝使用非目录: %s\n' "$dist_dir" >&2
        return 1
    }
    mkdir -p "$dist_dir"
    resolved_dist=$(cd "$dist_dir" && pwd -P)
    [[ "$resolved_dist" = "$dist_dir" ]] || {
        printf '发布目录解析异常: %s\n' "$resolved_dist" >&2
        return 1
    }
    [[ ! -L "$zip_path" ]] || {
        printf '拒绝覆盖符号链接: %s\n' "$zip_path" >&2
        return 1
    }
    [[ ! -e "$zip_path" || -f "$zip_path" ]] || {
        printf '拒绝覆盖非文件: %s\n' "$zip_path" >&2
        return 1
    }
}

rollback_publication() {
    local previous_app="$1"
    local previous_zip="$2"
    local app_publish_attempted="$3"
    local zip_publish_attempted="$4"
    local rollback_status=0
    local published_id=""

    if [[ "$zip_publish_attempted" = true && ( -e "$zip_path" || -L "$zip_path" ) ]]; then
        if [[ "$zip_path" = "$project_root/dist/ScreenClear-macos-arm64.zip" &&
              -f "$zip_path" && ! -L "$zip_path" ]]; then
            if ! /bin/rm -- "$zip_path"; then
                printf '无法移除失败的 ZIP: %s\n' "$zip_path" >&2
                rollback_status=1
            fi
        else
            printf '拒绝移除意外 ZIP 目标: %s\n' "$zip_path" >&2
            rollback_status=1
        fi
    fi
    if [[ -f "$previous_zip" && ! -L "$previous_zip" ]]; then
        if [[ ! -e "$zip_path" && ! -L "$zip_path" ]]; then
            if ! mv "$previous_zip" "$zip_path"; then
                printf '无法恢复原 ZIP: %s\n' "$zip_path" >&2
                rollback_status=1
            fi
        else
            printf 'ZIP 目标未腾空，无法恢复: %s\n' "$zip_path" >&2
            rollback_status=1
        fi
    fi

    if [[ "$app_publish_attempted" = true && ( -e "$project_app" || -L "$project_app" ) ]]; then
        published_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$project_app/Contents/Info.plist" 2>/dev/null || true)
        if [[ "$project_app" = "$project_root/ScreenClear.app" &&
              -d "$project_app" && ! -L "$project_app" &&
              "$published_id" = "$bundle_id" ]]; then
            if ! /bin/rm -rf -- "$project_app"; then
                printf '无法移除失败的应用: %s\n' "$project_app" >&2
                rollback_status=1
            fi
        else
            printf '拒绝移除意外应用目标: %s\n' "$project_app" >&2
            rollback_status=1
        fi
    fi
    if [[ -d "$previous_app" && ! -L "$previous_app" ]]; then
        if [[ ! -e "$project_app" && ! -L "$project_app" ]]; then
            if ! mv "$previous_app" "$project_app"; then
                printf '无法恢复原应用: %s\n' "$project_app" >&2
                rollback_status=1
            fi
        else
            printf '应用目标未腾空，无法恢复: %s\n' "$project_app" >&2
            rollback_status=1
        fi
    fi

    if [[ "$rollback_status" -ne 0 ]]; then
        preserve_stage=true
    fi
    return "$rollback_status"
}

publish_artifacts() {
    local previous_app="$stage_root/previous-project.app"
    local previous_zip="$stage_root/previous-project.zip"
    local app_publish_attempted=false
    local zip_publish_attempted=false

    validate_project_outputs || return 1

    if [[ -d "$project_app" ]]; then
        if ! mv "$project_app" "$previous_app"; then
            return 1
        fi
    fi
    if [[ -f "$zip_path" ]]; then
        if ! mv "$zip_path" "$previous_zip"; then
            rollback_publication "$previous_app" "$previous_zip" \
                "$app_publish_attempted" "$zip_publish_attempted" || true
            return 1
        fi
    fi

    app_publish_attempted=true
    if ! mv "$staged_app" "$project_app"; then
        rollback_publication "$previous_app" "$previous_zip" \
            "$app_publish_attempted" "$zip_publish_attempted" || true
        return 1
    fi
    zip_publish_attempted=true
    if ! mv "$staged_zip" "$zip_path"; then
        rollback_publication "$previous_app" "$previous_zip" \
            "$app_publish_attempted" "$zip_publish_attempted" || true
        return 1
    fi
    if ! codesign --verify --deep --strict --verbose=2 "$project_app"; then
        rollback_publication "$previous_app" "$previous_zip" \
            "$app_publish_attempted" "$zip_publish_attempted" || true
        return 1
    fi
    if ! unzip -tq "$zip_path"; then
        rollback_publication "$previous_app" "$previous_zip" \
            "$app_publish_attempted" "$zip_publish_attempted" || true
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

ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$staged_zip"
unzip -tq "$staged_zip"

publish_artifacts

if [[ "$install_requested" = true ]]; then
    install_app
fi

printf '✅ 生成 %s\n' "$project_app"
printf '✅ 打包 %s\n' "$zip_path"
