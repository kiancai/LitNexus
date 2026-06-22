#!/usr/bin/env bash
# 用 SPM 构建并手动组装成可双击的 LitNexus.app（无需 Xcode）。
# 用法：./make_app.sh [debug|release]   默认 release
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="LitNexus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/LitNexus" "$APP/Contents/MacOS/LitNexus"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LitNexus</string>
    <key>CFBundleDisplayName</key><string>LitNexus</string>
    <key>CFBundleExecutable</key><string>LitNexus</string>
    <key>CFBundleIdentifier</key><string>com.litnexus.app</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>0.2.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# ad-hoc 签名整个 bundle（无需开发者证书）。把下载后的「已损坏」降级为可右键打开的
# 「无法验证开发者」。彻底免提示仍需 Apple Developer ID 公证，个人项目暂不做。
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "（codesign 跳过：未找到 codesign）"

echo "已生成 $(pwd)/$APP"
