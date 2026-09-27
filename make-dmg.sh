#!/bin/bash
# 打一个可直接分发的 dmg（拖拽安装）
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/PinBox.app"
[ -d "$APP" ] || { echo "先跑 ./build.sh"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="dist/PinBox-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "▶ 准备内容…"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"

echo "▶ 生成 $DMG"
rm -f "$DMG"
hdiutil create -volname "PinBox" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "✅ 完成：$(pwd)/$DMG"
echo "   双击打开后，把 PinBox 拖到「应用程序」即可。"
