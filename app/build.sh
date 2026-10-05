#!/bin/bash
# 编译「WARP 开关.app」(universal：Apple 芯片 + Intel)，内置 usque 和 sing-box
#   ./build.sh            只编译，输出到 app/build/
#   ./build.sh --install  编译后安装到 /Applications
set -euo pipefail
cd "$(dirname "$0")"
NAME="WARP 开关"
VERSION="${VERSION:-1.0.0}"
OUT="build/$NAME.app"

command -v swiftc >/dev/null || { echo "需要 Swift 编译器：请先运行 xcode-select --install"; exit 1; }
[[ -x vendor/usque && -x vendor/sing-box ]] || ./fetch-vendor.sh

rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Helpers"

echo "==> 编译 App (arm64 + x86_64)"
for A in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$A-apple-macos13" main.swift -o "build/WarpSwitch-$A"
done
lipo -create build/WarpSwitch-arm64 build/WarpSwitch-x86_64 -output "$OUT/Contents/MacOS/WarpSwitch"

echo "==> 内置 usque / sing-box"
cp vendor/usque vendor/sing-box "$OUT/Contents/Helpers/"
cp -R vendor/licenses "$OUT/Contents/Resources/ThirdPartyLicenses"
cp ../LICENSE "$OUT/Contents/Resources/LICENSE.txt"

echo "==> 生成图标"
swiftc -swift-version 5 make-icon.swift -o build/make-icon
build/make-icon build/icon.png
IS=build/AppIcon.iconset; mkdir -p $IS
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out $IS/icon_${s}x${s}.png >/dev/null
  d=$((s*2)); sips -z $d $d build/icon.png --out $IS/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $IS -o "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.warp.switch</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>WarpSwitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License · 内置 usque (MIT) 与 sing-box (GPL-3.0)</string>
</dict></plist>
EOF

echo "==> 签名(本地 ad-hoc)"
codesign --force -s - "$OUT/Contents/Helpers/usque" "$OUT/Contents/Helpers/sing-box"
codesign --force -s - "$OUT"
codesign --verify --deep --strict "$OUT" && echo "签名校验通过"
rm -rf build/WarpSwitch-* build/make-icon build/AppIcon.iconset build/icon.png
echo "BUILT: $PWD/$OUT"

if [[ "${1:-}" == "--install" ]]; then
  DEST=/Applications
  [[ -w $DEST ]] || { DEST=$HOME/Applications; mkdir -p "$DEST"; }
  pkill -x WarpSwitch 2>/dev/null || true
  rm -rf "$DEST/$NAME.app"
  cp -R "$OUT" "$DEST/"
  echo "INSTALLED: $DEST/$NAME.app"
fi
