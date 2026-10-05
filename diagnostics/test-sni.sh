#!/bin/bash
# 用指定 SNI 临时起一个 usque,测试能否连上 WARP(不影响正在运行的服务)
# 用法: diagnostics/test-sni.sh <SNI> [h2|h3]
# 例子: diagnostics/test-sni.sh www.bing.com h2
DIR="$(cd "$(dirname "$0")/.." && pwd)"
SNI=${1:?用法: $0 <SNI> [h2|h3]}; MODE=${2:-h2}
LP=$((20000 + RANDOM % 5000))
EXTRA=(); [[ $MODE == h2 ]] && EXTRA=(--http2)
LOG=$(mktemp)
( cd "$DIR/usque" && exec ./usque socks -b 127.0.0.1 -p $LP -s "$SNI" "${EXTRA[@]}" ) >"$LOG" 2>&1 &
PID=$!
OUT=""
for i in 1 2 3 4 5 6; do
  sleep 2
  OUT=$(curl -s --max-time 6 -x socks5h://127.0.0.1:$LP https://www.cloudflare.com/cdn-cgi/trace | grep -E "^(warp|colo)=" | tr '\n' ' ')
  echo "$OUT" | grep -q "warp=on" && break
done
kill $PID 2>/dev/null; wait $PID 2>/dev/null
if echo "$OUT" | grep -q "warp=on"; then
  echo "✅ OK   sni=$SNI mode=$MODE  $OUT"
else
  echo "❌ FAIL sni=$SNI mode=$MODE  $(grep -o 'Failed to connect tunnel: .*' "$LOG" | tail -1 | cut -c1-120)"
fi
rm -f "$LOG"
