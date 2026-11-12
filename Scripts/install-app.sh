#!/bin/bash
# 构建并安装到 /Applications，然后重新打开 SideBar。
# 正在运行的 SideBar 会被正常退出：收纳的窗口先放回原位，重新打开后自动恢复收纳。
set -euo pipefail
cd "$(dirname "$0")/.."

app_id="com.ivean.SideBar"
installed="/Applications/SideBar.app"

Scripts/build-app.sh

# 只做正常退出；强杀会跳过“放回窗口”，窗口会留在屏幕外。
if pgrep -f "$installed/Contents/MacOS/SideBar" >/dev/null; then
  osascript -e "tell application id \"$app_id\" to quit"
  for _ in $(seq 1 20); do
    pgrep -f "$installed/Contents/MacOS/SideBar" >/dev/null || break
    sleep 0.5
  done
  if pgrep -f "$installed/Contents/MacOS/SideBar" >/dev/null; then
    echo "SideBar 没有在 10 秒内退出，已停止安装。请手动退出后重试。" >&2
    exit 1
  fi
fi

rm -rf "$installed"
ditto build/SideBar.app "$installed"
# 构建目录里的副本不需要被系统当成一个独立软件登记，免得“打开方式”等列表里出现多个 SideBar。
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/build/SideBar.app" >/dev/null 2>&1 || true
open -g "$installed"

if codesign -dr - "$installed" 2>&1 | grep -q "certificate leaf"; then
  echo "已安装并打开 SideBar（证书签名）。辅助功能授权在重装后保持有效。"
else
  echo "已安装并打开 SideBar（临时签名）。如果没有生效，请在 系统设置 > 隐私与安全性 > 辅助功能 里删掉 SideBar 再重新添加。"
fi
