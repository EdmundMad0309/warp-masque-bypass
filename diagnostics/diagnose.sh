#!/bin/bash
# 网络诊断：判断防火墙封的是什么(UDP / QUIC / IP / SNI),帮你选择方案
WARP_IP=162.159.198.2      # WARP MASQUE 入口
WG_IP=162.159.192.1        # WARP WireGuard 入口

echo "== 1. 普通 HTTPS(TCP 443)"
curl -s -o /dev/null --max-time 8 -w "cloudflare.com -> %{http_code}\n" https://www.cloudflare.com/cdn-cgi/trace || echo "失败：基础网络不通"

echo "== 2. UDP 53 (DNS)"
dig +time=3 +tries=1 @1.1.1.1 example.com A | grep -q "status: NOERROR" && echo "UDP 53 通" || echo "UDP 53 不通"

echo "== 3. QUIC / HTTP3 (UDP 443)"
BC=/opt/homebrew/opt/curl/bin/curl; [[ -x $BC ]] || BC=/usr/local/opt/curl/bin/curl
if [[ -x $BC ]] && $BC -V | grep -q HTTP3; then
  $BC -s -o /dev/null --http3-only --max-time 6 -w "QUIC 到 cloudflare.com -> v%{http_version}\n" https://www.cloudflare.com/ || echo "QUIC 不通"
else
  echo "跳过(需要 brew install curl 才支持 HTTP3)"
fi

echo "== 4. 到 WARP 入口的 TCP 443"
nc -z -G 3 -w 3 $WARP_IP 443 2>/dev/null && echo "$WARP_IP:443 TCP 通" || echo "$WARP_IP:443 TCP 不通(按 IP 封锁)"
nc -z -G 3 -w 3 $WG_IP 443 2>/dev/null && echo "$WG_IP:443 TCP 通" || echo "$WG_IP:443 TCP 不通"

echo "== 5. SNI 测试(对 WARP 入口做 TLS 握手)"
for sni in consumer-masque.cloudflareclient.com www.cloudflare.com; do
  T=$(curl -sk -o /dev/null --max-time 6 --resolve $sni:443:$WARP_IP -w "%{time_appconnect}" https://$sni/ 2>/dev/null)
  if [[ -n "$T" && "$T" != "0.000000" ]]; then echo "SNI=$sni 握手成功"; else echo "SNI=$sni 握手失败/被重置  <-- 按 SNI 封锁"; fi
done

echo
echo "解读：第 5 项默认 SNI 失败而 www.cloudflare.com 成功 => 本项目的方案适用"
echo "可继续用 diagnostics/test-sni.sh <域名> h2 测试具体 SNI"
