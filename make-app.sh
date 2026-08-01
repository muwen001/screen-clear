#!/bin/bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")" && pwd -P)
cd "$project_root"

install_requested=false
if [[ "$#" -gt 1 ]]; then
    printf '用法: %s [--install]\n' "$0" >&2
    exit 64
fi
if [[ "$#" -eq 1 ]]; then
    if [[ "$1" = "--install" ]]; then
        install_requested=true
    else
        printf '用法: %s [--install]\n' "$0" >&2
        exit 64
    fi
fi

. "$project_root/Scripts/Packaging/install-lifecycle.sh"

app_name="ScreenClear.app"
bundle_id="local.screenclear"
project_app="$project_root/$app_name"
dist_dir="$project_root/dist"
zip_path="$project_root/dist/ScreenClear-macos-arm64.zip"
install_target="/Applications/$app_name"
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/screenclear-build.XXXXXX")
staged_app="$stage_root/$app_name"
staged_zip="$stage_root/ScreenClear-macos-arm64.zip"
icon_generator="$project_root/Scripts/Icons/generate-icons.swift"
generated_resources="$stage_root/generated-resources"
staged_resources="$staged_app/Contents/Resources"
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
    local installed_executable="$install_target/Contents/MacOS/ScreenClear"
    local old_pids_output=""
    local new_pids_output=""
    local process_id
    local attempt
    local -a old_pids=()

    remove_new_install() {
        [[ "$install_target" = "/Applications/ScreenClear.app" ]] || return 1
        [[ -d "$install_target" && ! -L "$install_target" ]] || return 1
        if ! /bin/rm -rf -- "$install_target"; then
            printf '无法移除失败的新应用，停止回滚: %s\n' "$install_target" >&2
            return 1
        fi
        [[ ! -e "$install_target" && ! -L "$install_target" ]] || {
            printf '失败的新应用仍然存在，停止回滚: %s\n' "$install_target" >&2
            return 1
        }
    }

    rollback_install() {
        local active_pids_output=""
        local active_pid
        local -a active_pids=()

        if [[ -f "$installed_executable" && ! -L "$installed_executable" ]]; then
            active_pids_output=$(screenclear_pids_for_executable "$installed_executable") || {
                printf '无法检查失败新应用的进程，停止回滚\n' >&2
                return 1
            }
            while IFS= read -r active_pid; do
                [[ -n "$active_pid" ]] || continue
                active_pids+=("$active_pid")
            done <<< "$active_pids_output"
        fi

        if [[ "${#active_pids[@]}" -gt 0 ]]; then
            /usr/bin/osascript -e 'tell application id "local.screenclear" to quit' \
                >/dev/null 2>&1 || true
            if ! screenclear_wait_for_pids_to_exit 10 "${active_pids[@]}"; then
                printf '失败的新应用仍在运行，保留新旧 bundle 并停止: PID %s\n' \
                    "${active_pids[*]}" >&2
                return 1
            fi
        fi

        if [[ -e "$install_target" || -L "$install_target" ]]; then
            remove_new_install || return 1
        fi
        if [[ -d "$install_backup" && ! -L "$install_backup" ]]; then
            if ! mv "$install_backup" "$install_target"; then
                printf '无法恢复原应用，备份保留在: %s\n' "$install_backup" >&2
                return 1
            fi
        fi
    }

    validate_new_install() {
        local installed_id
        local minimum_system
        local icon_file
        local packaged_hash
        local installed_hash
        local relative_resource
        local packaged_resource
        local installed_resource
        local packaged_resource_hash
        local installed_resource_hash
        local details

        [[ -d "$install_target" && ! -L "$install_target" ]] || return 1
        [[ -x "$installed_executable" && ! -L "$installed_executable" ]] || return 1
        installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$install_target/Contents/Info.plist" 2>/dev/null || true)
        minimum_system=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
            "$install_target/Contents/Info.plist" 2>/dev/null || true)
        icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
            "$install_target/Contents/Info.plist" 2>/dev/null || true)
        [[ "$installed_id" = "$bundle_id" && "$minimum_system" = "14.0" &&
           "$icon_file" = "ScreenClear" ]] || return 1
        codesign --verify --deep --strict --verbose=2 "$install_target" || return 1
        details=$(codesign -dv --verbose=4 "$install_target" 2>&1) || return 1
        printf '%s\n' "$details" | grep -q '^Identifier=local.screenclear$' || return 1
        printf '%s\n' "$details" | grep -q '^Signature=adhoc$' || return 1
        file "$installed_executable" | grep -q 'Mach-O 64-bit executable arm64' || return 1
        packaged_hash=$(shasum -a 256 "$project_app/Contents/MacOS/ScreenClear" | awk '{print $1}')
        installed_hash=$(shasum -a 256 "$installed_executable" | awk '{print $1}')
        [[ "$packaged_hash" = "$installed_hash" ]] || return 1
        for relative_resource in ScreenClear.icns MenuBarIcon.pdf; do
            packaged_resource="$project_app/Contents/Resources/$relative_resource"
            installed_resource="$install_target/Contents/Resources/$relative_resource"
            [[ -f "$packaged_resource" && ! -L "$packaged_resource" && -s "$packaged_resource" ]] || return 1
            [[ -f "$installed_resource" && ! -L "$installed_resource" && -s "$installed_resource" ]] || return 1
            packaged_resource_hash=$(shasum -a 256 "$packaged_resource" | awk '{print $1}')
            installed_resource_hash=$(shasum -a 256 "$installed_resource" | awk '{print $1}')
            [[ "$packaged_resource_hash" = "$installed_resource_hash" ]] || return 1
        done
    }

    remove_install_backup() {
        local backup_id
        local backup_executable="$install_backup/Contents/MacOS/ScreenClear"
        local backup_pids=""

        [[ "$install_backup" = "/Applications/.ScreenClear.backup.$$" ]] || return 1
        [[ -d "$install_backup" && ! -L "$install_backup" ]] || return 1
        backup_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$install_backup/Contents/Info.plist" 2>/dev/null || true)
        [[ "$backup_id" = "$bundle_id" ]] || return 1
        backup_pids=$(screenclear_pids_for_executable "$backup_executable") || return 1
        [[ -z "$backup_pids" ]] || {
            printf '原应用备份仍被进程使用，保留并停止: PID %s\n' "$backup_pids" >&2
            return 1
        }
        if ! /bin/rm -rf -- "$install_backup"; then
            printf '无法移除原应用备份，停止: %s\n' "$install_backup" >&2
            return 1
        fi
        [[ ! -e "$install_backup" && ! -L "$install_backup" ]]
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
        [[ -x "$installed_executable" && ! -L "$installed_executable" ]] || {
            printf '现有应用缺少预期可执行文件: %s\n' "$installed_executable" >&2
            return 1
        }
        codesign --verify --deep --strict --verbose=2 "$install_target" || {
            printf '现有应用签名校验失败，拒绝替换\n' >&2
            return 1
        }

        old_pids_output=$(screenclear_pids_for_executable "$installed_executable") || {
            printf '无法记录现有应用进程，拒绝替换\n' >&2
            return 1
        }
        while IFS= read -r process_id; do
            [[ -n "$process_id" ]] || continue
            old_pids+=("$process_id")
        done <<< "$old_pids_output"
        if [[ "${#old_pids[@]}" -gt 0 ]]; then
            printf '现有 ScreenClear PID: %s\n' "${old_pids[*]}"
            /usr/bin/osascript -e 'tell application id "local.screenclear" to quit' \
                >/dev/null 2>&1 || true
            if ! screenclear_wait_for_pids_to_exit 10 "${old_pids[@]}"; then
                printf '现有 ScreenClear 未在时限内退出，安装目标保持不变: PID %s\n' \
                    "${old_pids[*]}" >&2
                return 1
            fi
            printf '现有 ScreenClear 已退出: %s\n' "${old_pids[*]}"
        else
            printf '现有 ScreenClear PID: 无\n'
        fi

        if ! mv "$install_target" "$install_backup"; then
            printf '无法保留原应用备份，安装目标保持不变\n' >&2
            return 1
        fi
    fi

    if ! ditto "$project_app" "$install_target"; then
        printf '复制新应用失败，开始恢复原应用\n' >&2
        if ! rollback_install; then
            printf '自动恢复失败，请保留现场并检查 %s\n' "$install_backup" >&2
        fi
        return 1
    fi
    if ! validate_new_install; then
        printf '新应用精确校验失败，开始恢复原应用\n' >&2
        if ! rollback_install; then
            printf '自动恢复失败，请保留现场并检查 %s\n' "$install_backup" >&2
        fi
        return 1
    fi

    if ! /usr/bin/open "$install_target"; then
        printf '启动新应用失败，开始恢复原应用\n' >&2
        if ! rollback_install; then
            printf '自动恢复失败，请保留现场并检查 %s\n' "$install_backup" >&2
        fi
        return 1
    fi

    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        new_pids_output=$(screenclear_new_pids_excluding_recorded \
            "$installed_executable" "$old_pids_output") || {
                printf '无法确认新应用进程，开始恢复原应用\n' >&2
                if ! rollback_install; then
                    printf '自动恢复失败，请保留现场并检查 %s\n' "$install_backup" >&2
                fi
                return 1
            }
        [[ -z "$new_pids_output" ]] || break
        sleep 1
    done
    if [[ -z "$new_pids_output" ]]; then
        printf '未发现来自精确安装路径的新进程，开始恢复原应用\n' >&2
        if ! rollback_install; then
            printf '自动恢复失败，请保留现场并检查 %s\n' "$install_backup" >&2
        fi
        return 1
    fi
    printf '新 ScreenClear PID: %s（可执行文件: %s）\n' \
        "$new_pids_output" "$installed_executable"

    if [[ -d "$install_backup" || -L "$install_backup" ]]; then
        remove_install_backup || return 1
    fi
}

swift build -c release
[[ -f "$icon_generator" && ! -L "$icon_generator" ]] || {
    printf '图标生成器缺失或不是普通文件: %s\n' "$icon_generator" >&2
    exit 1
}
mkdir -p "$generated_resources"
/usr/bin/xcrun swift "$icon_generator" "$generated_resources"

mkdir -p "$staged_app/Contents/MacOS" "$staged_resources"
cp .build/release/ScreenClear "$staged_app/Contents/MacOS/ScreenClear"
chmod 755 "$staged_app/Contents/MacOS/ScreenClear"
for resource_name in ScreenClear.icns MenuBarIcon.pdf; do
    generated_resource="$generated_resources/$resource_name"
    [[ -f "$generated_resource" && ! -L "$generated_resource" && -s "$generated_resource" ]] || {
        printf '生成的图标资源无效: %s\n' "$generated_resource" >&2
        exit 1
    }
    cp "$generated_resource" "$staged_resources/$resource_name"
done
/usr/bin/file "$staged_resources/ScreenClear.icns" | grep -q 'Mac OS X icon'
/usr/bin/file "$staged_resources/MenuBarIcon.pdf" | grep -q 'PDF document'
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
    <key>CFBundleIconFile</key><string>ScreenClear</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
plutil -lint "$staged_app/Contents/Info.plist"
codesign --force --deep --sign - --timestamp=none "$staged_app"
codesign --verify --deep --strict --verbose=2 "$staged_app"

ditto -c -k --norsrc --keepParent "$staged_app" "$staged_zip"
unzip -tq "$staged_zip"
if unzip -Z1 "$staged_zip" | grep -E '(^|/)\._|^__MACOSX/' >/dev/null; then
    printf 'ZIP 包含意外 AppleDouble 元数据\n' >&2
    exit 1
fi

publish_artifacts

if [[ "$install_requested" = true ]]; then
    install_app
fi

printf '✅ 生成 %s\n' "$project_app"
printf '✅ 打包 %s\n' "$zip_path"
