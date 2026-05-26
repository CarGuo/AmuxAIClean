#!/usr/bin/env bash
# make_dmg.sh —— GSYCleanMac alpha DMG 打包脚本（带美化）
#
# 用法：
#   ./scripts/make_dmg.sh <path-to-.app> [output.dmg]
# 例：
#   ./scripts/make_dmg.sh build/Build/Products/Debug/GSYCleanMac.app dist/GSYCleanMac-0.7.0-alpha.dmg
#
# 行为：
#   1. 优先用系统自带 hdiutil（无外部依赖）+ AppleScript 美化挂载窗口
#      - 自定义卷图标（用 AppIcon），解决"灰色磁盘图标"形态
#      - 自定义挂载窗口布局（图标视图、隐藏侧栏/工具栏、固定窗口与图标位置），解决"默认列表/凌乱图标"形态
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
  VOLUME_NAME      DMG 卷标，默认 "GSYCleanMac"
  USE_CREATE_DMG   设为 1 强制走 create-dmg fallback（跳过 hdiutil 主路径）
  DMG_BG_IMAGE     背景图路径（可选）。未显式提供时，若仓库存在
                   docs/assets/dmg-background.png 则自动启用为默认背景。
                   想完全去掉背景图：DMG_BG_IMAGE=/dev/null（脚本会忽略不存在路径）
  DMG_VOLUME_ICON  卷图标 .icns 路径（可选），未提供则尝试从 AppIcon 自动构建
  DMG_NO_BEAUTIFY  设为 1 跳过美化流程，等价旧版直出
EOF
  exit 64
fi

APP_PATH="$1"
DMG_PATH="${2:-dist/GSYCleanMac-alpha.dmg}"
VOLUME_NAME="${VOLUME_NAME:-GSYCleanMac}"
USE_CREATE_DMG="${USE_CREATE_DMG:-0}"
DMG_BG_IMAGE="${DMG_BG_IMAGE:-}"
DMG_VOLUME_ICON="${DMG_VOLUME_ICON:-}"
DMG_NO_BEAUTIFY="${DMG_NO_BEAUTIFY:-0}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APPICON_DIR="$ROOT_DIR/Resources/Assets.xcassets/AppIcon.appiconset"

# 内置默认背景图：docs/assets/dmg-background.png（由 Scripts/make_dmg_background.swift 生成）
# 若用户没显式指定 DMG_BG_IMAGE，且仓库里有这张内置图，则自动启用
DEFAULT_BG_IMAGE="$ROOT_DIR/docs/assets/dmg-background.png"
if [ -z "$DMG_BG_IMAGE" ] && [ -f "$DEFAULT_BG_IMAGE" ]; then
  DMG_BG_IMAGE="$DEFAULT_BG_IMAGE"
fi

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
WORK_DIR="$(mktemp -d -t gsycleanmac_dmg_work)"
cleanup() {
  # 兜底卸载（防止脚本中途失败留下挂载点）
  if [ -n "${MOUNT_DEV:-}" ] && [ -e "$MOUNT_DEV" ]; then
    hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || true
  fi
  if [ -n "${MOUNT_POINT:-}" ] && [ -d "$MOUNT_POINT" ]; then
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$STAGE_DIR" "$WORK_DIR"
}
trap cleanup EXIT

echo "==> 复制 $APP_BASENAME 到暂存目录（ditto 保留 xattr / 资源 fork）"
ditto "$APP_PATH" "$STAGE_DIR/$APP_BASENAME"

# 加 /Applications 软链接，方便用户拖装
ln -s /Applications "$STAGE_DIR/Applications"

# ----- 卷图标准备：把 AppIcon 转成 .icns 用作 DMG 卷图标 -----
prepare_volume_icon() {
  local out="$1"
  if [ -n "$DMG_VOLUME_ICON" ] && [ -f "$DMG_VOLUME_ICON" ]; then
    cp "$DMG_VOLUME_ICON" "$out"
    return 0
  fi
  if ! command -v iconutil >/dev/null 2>&1; then
    return 1
  fi
  local src1024="$APPICON_DIR/icon_1024x1024.png"
  if [ ! -f "$src1024" ]; then
    return 1
  fi
  local iconset="$WORK_DIR/VolumeIcon.iconset"
  mkdir -p "$iconset"
  # 用 sips 切出标准 iconset 切片
  sips -z 16   16   "$src1024" --out "$iconset/icon_16x16.png"      >/dev/null
  sips -z 32   32   "$src1024" --out "$iconset/icon_16x16@2x.png"   >/dev/null
  sips -z 32   32   "$src1024" --out "$iconset/icon_32x32.png"      >/dev/null
  sips -z 64   64   "$src1024" --out "$iconset/icon_32x32@2x.png"   >/dev/null
  sips -z 128  128  "$src1024" --out "$iconset/icon_128x128.png"    >/dev/null
  sips -z 256  256  "$src1024" --out "$iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256  256  "$src1024" --out "$iconset/icon_256x256.png"    >/dev/null
  sips -z 512  512  "$src1024" --out "$iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512  512  "$src1024" --out "$iconset/icon_512x512.png"    >/dev/null
  cp "$src1024" "$iconset/icon_512x512@2x.png"
  iconutil -c icns "$iconset" -o "$out"
}

# ----- 主路径：hdiutil + AppleScript 美化 -----
make_dmg_with_hdiutil() {
  echo "==> 使用 hdiutil 打包 DMG"

  if [ "$DMG_NO_BEAUTIFY" = "1" ]; then
    # 旧版直出，不美化
    hdiutil create \
      -volname "$VOLUME_NAME" \
      -srcfolder "$STAGE_DIR" \
      -ov \
      -format UDZO \
      -fs HFS+ \
      "$DMG_PATH"
    return $?
  fi

  # 1) 先创建可读写 DMG（UDRW，空白卷），稍后挂载后再 ditto 进内容并美化，最终压缩成 UDZO
  #    注意：用 -srcfolder 创建的 UDRW 实际上挂载后是只读的（HFS+ 卷被冻结），
  #    所以这里走"空白可写镜像 → 挂载 → ditto 内容 → 美化 → 压缩"的稳健路径。
  local rw_dmg="$WORK_DIR/rw.dmg"
  echo "    [1/5] 创建可读写镜像（UDRW，空白）"
  # 估算需要的容量：暂存目录大小 * 1.4 + 64MB 余量
  local stage_kb pad_mb
  stage_kb="$(du -sk "$STAGE_DIR" | awk '{print $1}')"
  pad_mb="$(( stage_kb / 1024 * 14 / 10 + 64 ))"
  hdiutil create \
    -volname "$VOLUME_NAME" \
    -size "${pad_mb}m" \
    -ov \
    -layout SPUD \
    -fs HFS+ \
    "$rw_dmg" >/dev/null

  # 2) 挂载
  echo "    [2/5] 挂载镜像"
  local attach_out
  attach_out="$(hdiutil attach "$rw_dmg" -readwrite -noverify -noautoopen -nobrowse)"
  MOUNT_DEV="$(echo "$attach_out" | awk '/^\/dev\// {print $1; exit}')"
  MOUNT_POINT="/Volumes/$VOLUME_NAME"

  if [ ! -d "$MOUNT_POINT" ]; then
    echo "    错误：挂载点未找到: $MOUNT_POINT"
    return 1
  fi

  # 2.5) 把暂存目录里的 .app + Applications 软链接 ditto 进卷
  ditto "$STAGE_DIR/" "$MOUNT_POINT/"

  # 3) 写入卷图标 + 背景图（可选）
  echo "    [3/5] 写入卷图标与背景图"
  local volicns="$WORK_DIR/VolumeIcon.icns"
  if prepare_volume_icon "$volicns"; then
    cp "$volicns" "$MOUNT_POINT/.VolumeIcon.icns"
    # 必须设置自定义图标 attribute（kHasCustomIcon），Finder 才会渲染
    SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
  else
    echo "    警告：未能生成卷图标，跳过自定义卷图标（DMG 仍然可用）"
  fi

  if [ -n "$DMG_BG_IMAGE" ] && [ -f "$DMG_BG_IMAGE" ]; then
    mkdir -p "$MOUNT_POINT/.background"
    cp "$DMG_BG_IMAGE" "$MOUNT_POINT/.background/background.png"
  fi

  # 4) AppleScript 美化窗口布局
  echo "    [4/5] AppleScript 美化挂载窗口"
  local has_bg="false"
  if [ -n "$DMG_BG_IMAGE" ] && [ -f "$DMG_BG_IMAGE" ]; then
    has_bg="true"
  fi

  /usr/bin/osascript <<APPLESCRIPT || echo "    警告：AppleScript 美化失败，使用默认布局"
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 1024, 620}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to true
        if $has_bg then
            try
                set background picture of viewOptions to file ".background:background.png"
            end try
        end if
        set position of item "$APP_BASENAME" of container window to {240, 230}
        set position of item "Applications" of container window to {580, 230}
        try
            set position of item ".background" of container window to {100, 800}
            set position of item ".VolumeIcon.icns" of container window to {220, 800}
            set position of item ".fseventsd" of container window to {340, 800}
            set position of item ".Trashes" of container window to {460, 800}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

  # 同步缓存，确保 .DS_Store 写盘
  sync || true
  sleep 1

  # 5) 卸载并压缩为 UDZO
  echo "    [5/5] 卸载并压缩为 UDZO"
  hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1 || \
    hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  MOUNT_DEV=""
  MOUNT_POINT=""

  hdiutil convert "$rw_dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH" >/dev/null
}

# ----- Fallback：create-dmg -----
make_dmg_with_create_dmg() {
  if ! command -v create-dmg >/dev/null 2>&1; then
    echo "错误: create-dmg 未安装。请先执行: brew install create-dmg" >&2
    return 127
  fi
  echo "==> 使用 create-dmg 打包 DMG (fallback)"

  local extra_args=()
  if [ -n "$DMG_BG_IMAGE" ] && [ -f "$DMG_BG_IMAGE" ]; then
    extra_args+=(--background "$DMG_BG_IMAGE")
  fi

  local volicns="$WORK_DIR/VolumeIcon.icns"
  if prepare_volume_icon "$volicns"; then
    extra_args+=(--volicon "$volicns")
  fi

  create-dmg \
    --volname "$VOLUME_NAME" \
    --window-pos 200 120 \
    --window-size 824 500 \
    --icon-size 128 \
    --text-size 13 \
    --icon "$APP_BASENAME" 240 230 \
    --app-drop-link 580 230 \
    --hide-extension "$APP_BASENAME" \
    --no-internet-enable \
    "${extra_args[@]}" \
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
