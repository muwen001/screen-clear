#!/bin/bash
# 手搓最小 .app bundle（无签名，本机自用）：消除裸可执行文件的 Dock 图标闪现
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="ScreenClear.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
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
EOF

cp .build/release/ScreenClear "$APP/Contents/MacOS/ScreenClear"
echo "✅ 生成 $APP"
echo "启动：open $APP"
