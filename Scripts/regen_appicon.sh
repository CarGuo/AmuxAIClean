#!/usr/bin/env bash
# 一次性脚本：用 /Users/guoshuyu/Desktop/logo.png 重新生成 AppIcon 全套尺寸 + docs/assets/logo.png
set -euo pipefail

SRC=/Users/guoshuyu/Desktop/logo.png
DST_DIR=/Users/guoshuyu/workspace/GSYCleanMac/Resources/Assets.xcassets/AppIcon.appiconset
DOCS_LOGO=/Users/guoshuyu/workspace/GSYCleanMac/docs/assets/logo.png

[ -f "$SRC" ] || { echo "缺失源图 $SRC" >&2; exit 1; }
[ -d "$DST_DIR" ] || { echo "缺失 $DST_DIR" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1) 等比缩到最长边 1024
sips -Z 1024 "$SRC" --out "$TMP/scaled.png" >/dev/null
# 2) padding 到 1024×1024 方形画布（白色背景；图本身的圆角/squircle alpha 通道仍保留）
sips -p 1024 1024 "$TMP/scaled.png" --padColor FFFFFF --out "$TMP/master.png" >/dev/null

echo "[gen] master 尺寸："
sips -g pixelWidth -g pixelHeight "$TMP/master.png" | tail -2

gen() {
    sips -Z "$1" "$TMP/master.png" --out "$DST_DIR/$2" >/dev/null
    printf "  -> %-26s %4spx\n" "$2" "$1"
}

gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png
gen 1024 icon_1024x1024.png

# 3) 同步 docs/assets/logo.png（用 512 版）
cp "$DST_DIR/icon_512x512.png" "$DOCS_LOGO"
echo "[gen] 已更新 $DOCS_LOGO"

echo "[gen] 完成"
