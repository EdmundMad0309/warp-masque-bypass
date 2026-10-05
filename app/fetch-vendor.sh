#!/bin/bash
# 准备 App 内置的 sing-box 和 usque(universal: arm64 + x86_64)，输出到 app/vendor/
#   - usque：下载官方 Release，用官方 checksums.txt 校验
#   - sing-box：官方 Release 带了大量用不到的功能(两架构合计 170MB+)，
#     这里从官方源码(固定 tag)不带额外 build tag 编译，只保留核心功能，体积小很多
set -euo pipefail
cd "$(dirname "$0")"
SB_VERSION=1.14.2
UQ_VERSION=4.2.1
V="$PWD/vendor"; rm -rf "$V"; mkdir -p "$V/dl" "$V/licenses"

# ---------- usque ----------
cd "$V/dl"
for A in arm64 amd64; do
  echo "==> 下载 usque $UQ_VERSION ($A)"
  curl -fsSL -O "https://github.com/Diniboy1123/usque/releases/download/v$UQ_VERSION/usque_${UQ_VERSION}_darwin_$A.zip"
done
curl -fsSL -o usque-checksums.txt "https://github.com/Diniboy1123/usque/releases/download/v$UQ_VERSION/checksums.txt"
grep darwin usque-checksums.txt | shasum -a 256 -c -
for A in arm64 amd64; do
  mkdir -p "uq-$A"; unzip -o -q "usque_${UQ_VERSION}_darwin_$A.zip" usque LICENSE.md -d "uq-$A"
done
lipo -create uq-arm64/usque uq-amd64/usque -output "$V/usque"
cp uq-arm64/LICENSE.md "$V/licenses/usque-LICENSE.txt"

# ---------- sing-box ----------
command -v go >/dev/null || { echo "需要 Go 编译 sing-box：brew install go"; exit 1; }
echo "==> 获取 sing-box v$SB_VERSION 源码"
git -c advice.detachedHead=false clone -q --depth 1 --branch "v$SB_VERSION" https://github.com/SagerNet/sing-box.git sb-src
cd sb-src
for A in arm64 amd64; do
  echo "==> 编译 sing-box ($A)"
  CGO_ENABLED=0 GOOS=darwin GOARCH=$A go build -trimpath \
    -ldflags "-s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=$SB_VERSION" \
    -o "../sb-$A" ./cmd/sing-box
done
cp LICENSE "$V/licenses/sing-box-LICENSE.txt"
cd ..
lipo -create sb-arm64 sb-amd64 -output "$V/sing-box"

printf 'sing-box %s (GPL-3.0) 源码: https://github.com/SagerNet/sing-box/tree/v%s  (无额外 build tag 编译)\nusque %s (MIT) 源码: https://github.com/Diniboy1123/usque/tree/v%s\n' \
  "$SB_VERSION" "$SB_VERSION" "$UQ_VERSION" "$UQ_VERSION" > "$V/licenses/SOURCES.txt"
cd "$V"; rm -rf dl
lipo -info sing-box usque
./sing-box version | head -1
ls -lh sing-box usque
