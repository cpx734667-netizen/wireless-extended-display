#!/bin/bash
# 无线扩展屏 macOS - 完整构建脚本
# 依赖：Xcode Command Line Tools（swiftc）、ffmpeg（brew install ffmpeg）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build"
ASSETS="$ROOT/assets"
APP_NAME="无线扩展屏"
APP="$BUILD/$APP_NAME.app"

BUNDLE_ID="com.wxes.mirror"
VERSION="1.1.0"

echo "=== 检查依赖 ==="
if ! command -v swiftc >/dev/null 2>&1; then
  echo "缺少 swiftc，请先安装 Xcode Command Line Tools：xcode-select --install"
  exit 1
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "缺少 ffmpeg，请先安装：brew install ffmpeg"
  exit 1
fi

echo "=== 清理旧包 ==="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "=== 1/5 编译主程序 ==="
cd "$SRC"
swiftc -O -swift-version 5 \
  main.swift H264.swift Decoder.swift Receiver.swift Sender.swift Ctrl.swift UI.swift \
  -o "$APP/Contents/MacOS/WXES"

echo "=== 2/5 封装 ffmpeg ==="
"$ROOT/scripts/package_ffmpeg.sh" "$APP"

echo "=== 3/5 生成图标 ==="
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
SIZES=(16 32 64 128 256 512)
for s in "${SIZES[@]}"; do
  sips -z "$s" "$s" "$ASSETS/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$ASSETS/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "=== 4/5 写入 Info.plist ==="
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>WXES</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>无线扩展屏 v$VERSION</string>
</dict>
</plist>
PLIST

echo "=== 5/5 代码签名（ad-hoc）==="
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "签名校验通过"

echo ""
echo "✅ 构建完成: $APP"
du -sh "$APP"
