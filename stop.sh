#!/bin/bash
# 停止服务、关闭登录自启，并清除 macOS 系统代理设置
U=$(id -u)
for s in singbox usque; do
  launchctl bootout "gui/$U" "$HOME/Library/LaunchAgents/com.warp.$s.plist" 2>/dev/null
  launchctl disable "gui/$U/com.warp.$s"
done
networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//' | while read -r svc; do
  networksetup -setwebproxystate "$svc" off 2>/dev/null
  networksetup -setsecurewebproxystate "$svc" off 2>/dev/null
  networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
done
echo "已停止，系统代理已清除，登录时不会再自动启动(运行 ./start.sh 恢复)"
