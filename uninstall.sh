#!/bin/bash
# 完全卸载：停止服务并删除 launchd 文件。保留本目录(含 WARP 账号 usque/config.json)。
DIR="$(cd "$(dirname "$0")" && pwd)"
"$DIR/stop.sh"
rm -f "$HOME/Library/LaunchAgents/com.warp.usque.plist" "$HOME/Library/LaunchAgents/com.warp.singbox.plist"
echo "已删除 launchd 服务。如需彻底清理可删除本目录，并 brew uninstall sing-box"
