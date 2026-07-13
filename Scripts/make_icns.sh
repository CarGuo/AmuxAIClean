#!/usr/bin/env bash
#
# scripts/make_icns.sh —— 一键把任意源图变成符合 Apple HIG 的 macOS AppIcon
#
# 用法：
#   scripts/make_icns.sh                                  # 用默认源图与默认背景
#   scripts/make_icns.sh /path/to/source.png              # 指定源图
#   ICON_BG="#0EA5E9" scripts/make_icns.sh                # 指定背景色（rrggbb）
#   ICON_PADDING=0.10 scripts/make_icns.sh                # 留白比例（默认 0.12）
#
# 实现要点：
#   1. 用 swift CoreGraphics 渲染一张 1024×1024 的"squircle 背景 + 居中 logo + 圆角裁切"
#      —— 见 scripts/make_app_icon.swift（避免装 Pillow / ImageMagick）。
#   2. 然后用 sips 切出 Apple HIG 要求的 10 张尺寸（16/32/128/256/512，各含 1x/2x）。
#   3. macOS Big Sur 以后规范：圆角 22.37%、四角留白 ~12%，详见 Apple HIG。
#   4. 修复 TCC 列表灰方块：build 完后 tccutil reset SystemPolicyAllFiles + 重新授权一次。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$HOME/Desktop/mac-logo.png}"
BG="${ICON_BG:-#0EA5E9}"
PADDING="${ICON_PADDING:-0.12}"
APPICON_DIR="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
TMP_1024="$(mktemp -t gsyclean_icon_1024).png"

if [[ ! -f "$SRC" ]]; then
  echo "ERR: 源图不存在: $SRC" >&2
  exit 1
fi

echo "[icon] 源图: $SRC"
echo "[icon] 背景色: $BG / 留白: $PADDING"
echo "[icon] 输出: $APPICON_DIR"

# 1) 用 Swift 单文件脚本生成"squircle 背景 + 居中 logo"的 1024×1024 母版
swift "$ROOT/scripts/make_app_icon.swift" "$SRC" "$TMP_1024" "$BG" "$PADDING"

# 2) sips 切尺寸 —— 名字必须严格对应 AppIcon.appiconset/Contents.json 里的 filename
declare -a SIZES=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)
for entry in "${SIZES[@]}"; do
  px="${entry%%:*}"
  name="${entry##*:}"
  sips -z "$px" "$px" "$TMP_1024" --out "$APPICON_DIR/$name" >/dev/null
  echo "  ✓ $name (${px}×${px})"
done

rm -f "$TMP_1024"

echo ""
echo "[icon] 全部 10 张已落到 AppIcon.appiconset。"
echo "[icon] 接下来跑：xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac ... 看 Contents/Resources/AppIcon.icns"
echo ""
echo "[hint] 若系统设置「完全磁盘访问」列表里 GSYCleanMac 仍是灰方块，可执行："
echo "       tccutil reset SystemPolicyAllFiles com.gsy.cleanmac"
echo "       然后重新授权一次（系统会重新读你新版的 AppIcon）。"
