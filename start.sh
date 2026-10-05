#!/bin/bash
# 启动服务并开启登录自启
DIR="$(cd "$(dirname "$0")" && pwd)"
U=$(id -u)
for s in usque singbox; do
  P="$HOME/Library/LaunchAgents/com.warp.$s.plist"
  [[ -f "$P" ]] || { echo "找不到 $P,请先运行 ./install.sh"; exit 1; }
  launchctl enable "gui/$U/com.warp.$s"
  launchctl bootout "gui/$U" "$P" 2>/dev/null
  launchctl bootstrap "gui/$U" "$P"
done
echo "==> 已启动，等待隧道建立..."
for i in $(seq 1 10); do
  sleep 2
  OUT=$(curl -s --max-time 6 -x http://127.0.0.1:7890 https://www.cloudflare.com/cdn-cgi/trace | grep -E "^(ip|colo|warp)=")
  if echo "$OUT" | grep -q "warp=on"; then echo "$OUT"; echo "✅ 已连接 WARP"; exit 0; fi
done
echo "❌ 20 秒内未连上，请查看日志: tail -20 $DIR/usque.log"
exit 1
