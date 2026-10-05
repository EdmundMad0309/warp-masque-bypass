#!/bin/bash
# 一键安装：安装 sing-box、下载并校验 usque、注册 WARP 设备、生成 launchd 自启服务并启动。
# 可重复运行(已存在的部分会跳过),修改 config.env 后重新运行即可生效。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
source ./config.env

USQUE_VERSION=4.2.1
LA="$HOME/Library/LaunchAgents"

[[ "$(uname)" == "Darwin" ]] || { echo "仅支持 macOS"; exit 1; }
command -v brew >/dev/null || { echo "请先安装 Homebrew: https://brew.sh"; exit 1; }

# 1. sing-box
if ! command -v sing-box >/dev/null; then
  echo "==> 安装 sing-box"
  brew install sing-box
fi
SINGBOX="$(command -v sing-box)"

# 2. usque (从 GitHub Release 下载并校验 SHA256)
mkdir -p usque
if [[ ! -x usque/usque ]]; then
  case "$(uname -m)" in
    arm64) ARCH=arm64 ;;
    x86_64) ARCH=amd64 ;;
    *) echo "不支持的架构 $(uname -m)"; exit 1 ;;
  esac
  ZIP="usque_${USQUE_VERSION}_darwin_${ARCH}.zip"
  BASE="https://github.com/Diniboy1123/usque/releases/download/v${USQUE_VERSION}"
  echo "==> 下载 usque v${USQUE_VERSION} (${ARCH})"
  ( cd usque
    curl -fsSL -O "$BASE/$ZIP"
    curl -fsSL -o checksums.txt "$BASE/checksums.txt"
    grep " $ZIP\$" checksums.txt | shasum -a 256 -c -
    unzip -o -q "$ZIP" usque
    rm -f "$ZIP"
    xattr -d com.apple.quarantine usque 2>/dev/null || true
    chmod +x usque )
fi

# 3. 注册 WARP 设备(只在没有 config.json 时进行)
if [[ ! -f usque/config.json ]]; then
  echo "==> 注册 Cloudflare WARP 设备(视为同意 Cloudflare 服务条款)"
  ( cd usque && ./usque register -a )
fi
chmod 600 usque/config.json

# 4. 校验 sing-box 配置
"$SINGBOX" check -c singbox.json

# 5. 生成 launchd 服务(登录自启 + 崩溃自动重启)
mkdir -p "$LA"
plist() { # label workdir log args...
  local label=$1 wd=$2 log=$3; shift 3
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Label</key><string>$label</string>"
    echo '  <key>ProgramArguments</key><array>'
    for a in "$@"; do echo "    <string>$a</string>"; done
    echo '  </array>'
    echo "  <key>WorkingDirectory</key><string>$wd</string>"
    echo '  <key>RunAtLoad</key><true/>'
    echo '  <key>KeepAlive</key><true/>'
    echo '  <key>ThrottleInterval</key><integer>5</integer>'
    echo "  <key>StandardOutPath</key><string>$log</string>"
    echo "  <key>StandardErrorPath</key><string>$log</string>"
    echo '</dict></plist>'
  } > "$LA/$label.plist"
  plutil -lint -s "$LA/$label.plist"
}
plist com.warp.usque "$DIR/usque" "$DIR/usque.log" \
  "$DIR/usque/usque" -c "$DIR/usque/config.json" socks -b 127.0.0.1 -p "$USQUE_PORT" --http2 -s "$SNI"
plist com.warp.singbox "$DIR" "$DIR/singbox.log" \
  "$SINGBOX" run -c "$DIR/singbox.json"
echo "==> 已写入 $LA/com.warp.{usque,singbox}.plist (SNI=$SNI)"

# 6. 启动
exec "$DIR/start.sh"
