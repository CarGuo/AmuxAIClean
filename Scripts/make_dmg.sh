#!/usr/bin/env bash
# make_dmg.sh —— GSYCleanMac alpha DMG 打包脚本
#
# 用法：
#   ./scripts/make_dmg.sh <path-to-.app> [output.dmg]
# 例：
#   ./scripts/make_dmg.sh build/Build/Products/Debug/GSYCleanMac.app dist/GSYCleanMac-0.7.0-alpha.dmg
#
# 行为：
#   1. 优先用系统自带 hdiutil（无外部依赖）
#   2. hdiutil 失败时 fallback 到 create-dmg（brew install create-dmg）
#   3. 复制 .app 走 ditto（保留 extended attributes / 资源 fork / 符号链接）
#
# 注意：
#   - 本脚本不做公证（Notarization），alpha 阶段先出包
#   - PITFALLS §4.4：公证后必须 xcrun stapler staple <dmg>，由 codesign.sh 后续流程负责

set -euo pipefail

# ----- 参数解析 -----
if [ $# -lt 1 ]; then
  cat <<EOF >&2
用法: $0 <path-to-.app> [output.dmg]

例:
  $0 build/Build/Products/Debug/GSYCleanMac.app
  $0 build/Build/Products/Debug/GSYCleanMac.app dist/GSYCleanMac-0.7.0-alpha.dmg

环境变量:
  VOLUME_NAME     DMG 卷标，默认 "GSYCleanMac"
  USE_CREATE_DMG  设为 1 强制走 create-dmg fallback（跳过 hdiutil 主路径）
EOF
  exit 64
fi

APP_PATH="$1"
DMG_PATH="${2:-dist/GSYCleanMac-alpha.dmg}"
VOLUME_NAME="${VOLUME_NAME:-GSYCleanMac}"
USE_CREATE_DMG="${USE_CREATE_DMG:-0}"

# ----- 校验输入 -----
if [ ! -d "$APP_PATH" ]; then
  echo "错误: 找不到 .app: $APP_PATH" >&2
  exit 66
fi

case "$APP_PATH" in
  *.app) ;;
  *) echo "错误: 输入必须是 .app bundle: $APP_PATH" >&2; exit 65 ;;
esac

APP_BASENAME="$(basename "$APP_PATH")"

# 准备输出目录
DMG_DIR="$(dirname "$DMG_PATH")"
mkdir -p "$DMG_DIR"

# 已有同名 DMG 先删（避免 hdiutil "file exists" 报错）
if [ -f "$DMG_PATH" ]; then
  echo "==> 移除已存在的 DMG: $DMG_PATH"
  rm -f "$DMG_PATH"
fi

# ----- 准备暂存目录 -----
STAGE_DIR="$(mktemp -d -t gsycleanmac_dmg_stage)"
cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

echo "==> 复制 $APP_BASENAME 到暂存目录（ditto 保留 xattr / 资源 fork）"
ditto "$APP_PATH" "$STAGE_DIR/$APP_BASENAME"

# 加 /Applications 软链接，方便用户拖装
ln -s /Applications "$STAGE_DIR/Applications"

# ----- 主路径：hdiutil -----
make_dmg_with_hdiutil() {
  echo "==> 使用 hdiutil 打包 DMG"
  hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"
}

# ----- Fallback：create-dmg -----
make_dmg_with_create_dmg() {
  if ! command -v create-dmg >/dev/null 2>&1; then
    echo "错误: create-dmg 未安装。请先执行: brew install create-dmg" >&2
    return 127
  fi
  echo "==> 使用 create-dmg 打包 DMG (fallback)"
  create-dmg \
    --volname "$VOLUME_NAME" \
    --window-pos 200 120 \
    --window-size 600 380 \
    --icon-size 96 \
    --icon "$APP_BASENAME" 160 180 \
    --app-drop-link 440 180 \
    --hide-extension "$APP_BASENAME" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGE_DIR"
}

# ----- 打包逻辑 -----
if [ "$USE_CREATE_DMG" = "1" ]; then
  make_dmg_with_create_dmg
else
  if ! make_dmg_with_hdiutil; then
    echo "==> hdiutil 失败，尝试 create-dmg fallback"
    make_dmg_with_create_dmg
  fi
fi

# ----- 校验产物 -----
if [ ! -f "$DMG_PATH" ]; then
  echo "错误: DMG 未生成: $DMG_PATH" >&2
  exit 70
fi

DMG_SIZE="$(du -sh "$DMG_PATH" | awk '{print $1}')"
echo
echo "==> DMG 打包完成"
echo "    路径: $DMG_PATH"
echo "    体积: $DMG_SIZE"
echo "    卷标: $VOLUME_NAME"
echo
echo "下一步（公证流程，alpha 可跳过）："
echo "  1. ./Scripts/codesign.sh $APP_PATH        # Developer ID 签名"
echo "  2. xcrun notarytool submit $DMG_PATH ..."
echo "  3. xcrun stapler staple $DMG_PATH        # 公证票据 staple"
echo "  4. spctl -a -vv -t open --context context:primary-signature $DMG_PATH"
