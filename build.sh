#!/bin/bash
# 编译并打包成 dist/PinBox.app（可直接拖进「应用程序」）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PinBox"
DIST="dist"
BUNDLE="$DIST/$APP_NAME.app"
IDENTITY="PinBox Local Signing"

echo "▶ 编译…"
swift build -c release

echo "▶ 生成图标…"
[ -f Resources/AppIcon.icns ] || swift Resources/make-icon.swift Resources/AppIcon.icns

echo "▶ 组装 $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/release/$APP_NAME "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "▶ 签名…"
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    # 用固定自签名身份：屏幕录制权限能在重新构建后保留
    codesign --force --deep --sign "$IDENTITY" "$BUNDLE"
    echo "  已用「${IDENTITY}」签名（自签名未被系统信任是正常的，本机运行不受影响）"
else
    codesign --force --deep --sign - "$BUNDLE"
    echo "  ⚠️ 用的 ad-hoc 签名：每次重新构建后可能需要重新授予屏幕录制权限"
    echo "     想避免的话先跑 ./create-identity.sh"
fi
codesign --verify --verbose=1 "$BUNDLE" 2>&1 | tail -1 || true

echo "✅ 完成：$(pwd)/$BUNDLE"
echo "   安装：./install.sh   （或把 $APP_NAME.app 拖进 /Applications）"
echo "   做安装包：./make-dmg.sh"
