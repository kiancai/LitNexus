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

# 品牌图同时作为应用内侧栏标记与 macOS 应用图标来源。源 PNG 保留在 Assets，
# 每次打包生成所需的 .icns，避免仓库里维护多份二进制图标。
if [[ -f "Assets/Brand/litnexus-mark.png" ]]; then
    cp "Assets/Brand/litnexus-mark.png" "$APP/Contents/Resources/litnexus-mark.png"
    ICONSET="$APP/Contents/Resources/LitNexus.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16   "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_16x16.png" >/dev/null
    sips -z 32 32   "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
    sips -z 32 32   "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_32x32.png" >/dev/null
    sips -z 64 64   "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_128x128.png" >/dev/null
    sips -z 256 256 "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_256x256.png" >/dev/null
    sips -z 512 512 "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "Assets/Brand/litnexus-mark.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/LitNexus.icns"
    rm -rf "$ICONSET"
fi

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
    <key>CFBundleIconFile</key><string>LitNexus</string>
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
