#!/bin/bash
# 打包成可分发的 DMG：app/dist/WARP-Switch-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0.0}"
NAME="WARP 开关"
DMG="dist/WARP-Switch-$VERSION.dmg"

VERSION=$VERSION ./build.sh

echo "==> 制作 DMG"
rm -rf dist build/dmg && mkdir -p dist build/dmg
cp -R "build/$NAME.app" build/dmg/
ln -s /Applications build/dmg/Applications
cat > "build/dmg/安装说明.txt" <<'EOF'
安装：把「WARP 开关」拖到右边的 Applications(应用程序)文件夹，然后从启动台打开。

第一次打开如果提示"无法打开"或"无法验证开发者"：
  打开 系统设置 → 隐私与安全性，在页面底部点「仍要打开」。
  (或在终端运行：xattr -dr com.apple.quarantine "/Applications/WARP 开关.app")

本软件未经 Apple 公证(没有付费开发者账号)，源码完全公开。
EOF
hdiutil create -quiet -volname "WARP 开关 $VERSION" -srcfolder build/dmg -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
rm -rf build/dmg
( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
ls -lh dist
cat dist/*.sha256
