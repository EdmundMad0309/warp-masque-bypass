#!/bin/bash
# 编译并安装 "WARP 开关.app" 到 /Applications(失败则装到 ~/Applications)
set -euo pipefail
cd "$(dirname "$0")"
NAME="WARP 开关"
OUT="build/$NAME.app"
rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

command -v swiftc >/dev/null || { echo "需要 Swift 编译器：请先运行 xcode-select --install"; exit 1; }
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13" main.swift -o "$OUT/Contents/MacOS/WarpSwitch"

# 图标
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
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --deep -s - "$OUT"

DEST=/Applications
[[ -w $DEST ]] || { DEST=$HOME/Applications; mkdir -p "$DEST"; }
pkill -x WarpSwitch 2>/dev/null || true
rm -rf "$DEST/$NAME.app"
cp -R "$OUT" "$DEST/"
echo "INSTALLED: $DEST/$NAME.app"
