#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/SideBar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# 只生成仓库内产物，不安装、不启动、不写 defaults。
swiftc Sources/SideBar/*.swift -O -target "$(uname -m)-apple-macosx12.3" \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework Foundation \
  -o "$app/Contents/MacOS/SideBar"
cp Info.plist "$app/Contents/Info.plist"
cp Sources/*.png Sources/*.icns Sources/*.svg "$app/Contents/Resources/"
cp Sources/SettingsTabIcons/*.svg "$app/Contents/Resources/"
cp -R Sources/Recommends "$app/Contents/Resources/"
# 优先用钥匙串里的本地自签名证书：签名身份稳定，重装后辅助功能授权不失效。
# 找不到证书时退回临时签名（每次构建都要重新授权）。都不代表开发者签名或公证。
identity="${SIDEBAR_SIGN_IDENTITY:-SideBar Local Signing}"
if security find-identity -p codesigning | grep -q "\"$identity\""; then
  codesign --force --sign "$identity" "$app"
else
  echo "未找到签名证书「$identity」，使用临时签名" >&2
  codesign --force --sign - "$app"
fi
echo "Built (not launched): $app"
