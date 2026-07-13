#!/usr/bin/env bash
# Read-only proof for an AmuxAIClean distribution DMG.
# Usage: verify_dmg.sh <dmg-path> <expected-app-name.app> [provenance-sidecar]

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "用法: $0 <dmg-path> <expected-app-name.app> [provenance-sidecar]" >&2
  exit 64
fi

DMG_PATH="$1"
APP_BASENAME="$2"
PROVENANCE_FILE="${3:-}"

[ -f "$DMG_PATH" ] || { echo "错误: DMG 不存在: $DMG_PATH" >&2; exit 66; }
case "$APP_BASENAME" in
  *.app) ;;
  *) echo "错误: 预期 App 名必须以 .app 结尾: $APP_BASENAME" >&2; exit 65 ;;
esac
if [ -n "$PROVENANCE_FILE" ] && [ ! -f "$PROVENANCE_FILE" ]; then
  echo "错误: provenance sidecar 不存在: $PROVENANCE_FILE" >&2
  exit 66
fi

WORK_DIR="$(mktemp -d -t amuxaiclean_dmg_verify)"
MOUNT_DEV=""
MOUNT_POINT=""

detach_active_mount() {
  if [ -z "${MOUNT_DEV:-}" ] && [ -z "${MOUNT_POINT:-}" ]; then
    return 0
  fi
  if [ -n "${MOUNT_DEV:-}" ] && hdiutil detach "$MOUNT_DEV" >/dev/null 2>&1; then
    MOUNT_DEV=""; MOUNT_POINT=""; return 0
  fi
  if [ -n "${MOUNT_DEV:-}" ] && hdiutil detach "$MOUNT_DEV" -force >/dev/null 2>&1; then
    MOUNT_DEV=""; MOUNT_POINT=""; return 0
  fi
  if [ -n "${MOUNT_POINT:-}" ] && hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1; then
    MOUNT_DEV=""; MOUNT_POINT=""; return 0
  fi
  if [ -n "${MOUNT_POINT:-}" ] && hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1; then
    MOUNT_DEV=""; MOUNT_POINT=""; return 0
  fi
  echo "错误: 无法卸载验证镜像（device=${MOUNT_DEV:-unknown}, mount=${MOUNT_POINT:-unknown}）" >&2
  return 1
}

cleanup() {
  detach_active_mount >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

parse_attach_plist() {
  local plist="$1" index=0 dev point
  local found=0 selected_dev="" selected_point=""
  while dev="$(/usr/libexec/PlistBuddy -c "Print :system-entities:${index}:dev-entry" "$plist" 2>/dev/null)"; do
    if point="$(/usr/libexec/PlistBuddy -c "Print :system-entities:${index}:mount-point" "$plist" 2>/dev/null)" \
      && [ -n "$point" ]; then
      found=$((found + 1))
      selected_dev="$dev"
      selected_point="$point"
    fi
    index=$((index + 1))
  done
  [ "$found" -eq 1 ] || {
    echo "错误: attach plist 中预期 1 个挂载卷，实际 ${found} 个" >&2
    return 1
  }
  case "$selected_dev" in
    /dev/*) ;;
    *) echo "错误: attach plist 返回无效设备: $selected_dev" >&2; return 1 ;;
  esac
  MOUNT_DEV="$selected_dev"
  MOUNT_POINT="$selected_point"
}

echo "==> 只读验证最终 DMG: $DMG_PATH"
hdiutil verify "$DMG_PATH" >/dev/null

requested_mount="$WORK_DIR/mount"
mkdir -p "$requested_mount"
expected_mount="$(cd "$requested_mount" && pwd -P)"
MOUNT_POINT="$expected_mount"
attach_plist="$WORK_DIR/attach.plist"
hdiutil attach "$DMG_PATH" -readonly -noautoopen -nobrowse \
  -mountpoint "$expected_mount" -plist > "$attach_plist"
parse_attach_plist "$attach_plist"
actual_mount="$(cd "$MOUNT_POINT" && pwd -P)"
[ "$actual_mount" = "$expected_mount" ] || {
  echo "错误: hdiutil 实际验证挂载点不符: $actual_mount" >&2
  exit 70
}
MOUNT_POINT="$actual_mount"

APP_PATH="$MOUNT_POINT/$APP_BASENAME"
PLIST="$APP_PATH/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "错误: DMG 内缺少有效 App bundle: $APP_BASENAME" >&2; exit 70; }
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
[ -n "$executable" ] && [ -x "$APP_PATH/Contents/MacOS/$executable" ] || {
  echo "错误: DMG 内 App 主可执行文件缺失或不可执行" >&2
  exit 70
}
codesign --verify --deep --strict --verbose=4 "$APP_PATH"
[ -L "$MOUNT_POINT/Applications" ] \
  && [ "$(readlink "$MOUNT_POINT/Applications")" = "/Applications" ] || {
    echo "错误: DMG 内 Applications 安装链接无效" >&2
    exit 70
  }
if [ -n "$PROVENANCE_FILE" ]; then
  cmp -s "$PROVENANCE_FILE" "$MOUNT_POINT/.build-provenance.json" || {
    echo "错误: DMG 内构建溯源与 sidecar 不一致" >&2
    exit 70
  }
fi

detach_active_mount
cleanup
trap - EXIT
echo "  ✓ DMG 镜像、App 签名、安装链接与 provenance 内容一致"
