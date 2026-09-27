#!/bin/bash
# 安装到 /Applications 并启动
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/PinBox.app"
[ -d "$APP" ] || { echo "先跑 ./build.sh"; exit 1; }

echo "▶ 关闭正在运行的 PinBox…"
pkill -x PinBox 2>/dev/null || true
sleep 1

echo "▶ 安装到 /Applications…"
rm -rf "/Applications/PinBox.app"
cp -R "$APP" /Applications/
xattr -dr com.apple.quarantine "/Applications/PinBox.app" 2>/dev/null || true

echo "▶ 启动…"
open "/Applications/PinBox.app"
echo "✅ 已安装并启动。菜单栏会出现一个图钉图标；首次需要授予「屏幕录制」权限。"
