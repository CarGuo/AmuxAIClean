#!/usr/bin/env bash
# 由内向外的显式签名脚本（PITFALLS §1.3 / §4.2）。
# 严格禁止 --deep；所有内嵌可执行必须独立签 hardened runtime。
set -euo pipefail

APP="$1"
IDENTITY="${IDENTITY:-Developer ID Application}"

if [ -z "${APP:-}" ]; then
  echo "用法: IDENTITY='Developer ID Application: Your Name (TEAMID)' $0 path/to/GSYCleanMac.app"
  exit 64
fi

echo "==> 签名 Helper"
HELPER="$APP/Contents/Library/LaunchServices/com.guoshuyu.cleanmac.helper"
if [ -f "$HELPER" ]; then
  codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "$HELPER"
fi

# Sparkle 自更新内嵌可执行（若引入 Sparkle，PITFALLS §4.1）
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  for bin in \
    "$SPARKLE/Versions/A/Resources/Autoupdate.app/Contents/MacOS/Autoupdate" \
    "$SPARKLE/Versions/A/Resources/Autoupdate.app/Contents/MacOS/fileop"; do
    [ -f "$bin" ] && codesign --force --options runtime --timestamp --sign "$IDENTITY" "$bin"
  done
  codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$SPARKLE/Versions/A/Resources/Autoupdate.app"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$SPARKLE"
fi

echo "==> 签名主 App（最后）"
codesign --force --options runtime --timestamp \
  --entitlements "$(dirname "$0")/../App/GSYCleanMac.entitlements" \
  --sign "$IDENTITY" "$APP"

echo "==> 校验"
codesign -vvv --strict "$APP"
spctl -a -vv -t exec "$APP" || echo "(spctl 在公证 staple 之后才会显示 accepted)"
