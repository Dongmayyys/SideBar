#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/SideBar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# 只生成仓库内产物，不安装、不启动、不写 defaults。
compile() {
  swiftc Sources/SideBar/*.swift -O -target "$(uname -m)-apple-macosx12.3" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices -framework Foundation \
    -o "$app/Contents/MacOS/SideBar"
}

# SDK 选择：显式 SDKROOT > 上次成功的 SDK > 系统默认 SDK > 命令行工具里其他版本的 SDK。
# 部分机器上默认 SDK 与 swiftc 工具链不匹配会编译失败，换一个版本的 SDK 即可。
sdk_cache="$PWD/build/.sdkroot"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if [ -n "${SDKROOT:-}" ]; then
  compile
else
  candidates=()
  if [ -f "$sdk_cache" ] && [ -d "$(cat "$sdk_cache")" ]; then candidates+=("$(cat "$sdk_cache")"); fi
  candidates+=("")
  for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -r); do
    candidates+=("$sdk")
  done
  built=0
  for sdk in "${candidates[@]}"; do
    if [ -n "$sdk" ]; then echo "使用 SDK：$sdk" >&2; fi
    if ( if [ -n "$sdk" ]; then export SDKROOT="$sdk"; else unset SDKROOT; fi; compile ) 2>"$log"; then
      if [ -n "$sdk" ]; then echo "$sdk" > "$sdk_cache"; else rm -f "$sdk_cache"; fi
      built=1
      break
    fi
    echo "编译失败，换下一个 SDK 重试" >&2
  done
  if [ "$built" -ne 1 ]; then cat "$log" >&2; exit 1; fi
fi
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
