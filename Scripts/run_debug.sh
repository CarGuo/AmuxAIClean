#!/usr/bin/env bash
#
# Debug 一键运行
#
# 做了什么：
#   1. 杀光所有正在跑的 AmuxAIClean 进程（避免老版本残留）
#   2. xcodebuild Debug 增量 build（签名走 .xcodeproj 里 Xcode UI 配的 Manual + Apple Distribution 企业证书）
#   3. 用 xcodebuild -showBuildSettings 动态查 BUILT_PRODUCTS_DIR，从那里启动 .app
#   4. activate 到前台
#
# 用法：
#   ./Scripts/run_debug.sh                # 增量 build + 启动
#   ./Scripts/run_debug.sh --clean        # clean 后再 build + 启动
#   ./Scripts/run_debug.sh --no-build     # 只启动，不 build
#
# 设计原则（Step 5.6 番外回归 Xcode 原生路径）：
#   - 不再做签名身份决议三级 fallback；签名完全由 .xcodeproj 决定
#   - 不再调用 xcodegen；.xcodeproj 已入仓，直接用
#   - 路径用 -showBuildSettings 动态查，避免硬编码 DerivedData hash 跨机器失效

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="GSYCleanMac"
PROJECT="${ROOT}/GSYCleanMac.xcodeproj"
APP_NAME="AmuxAIClean"
EXECUTABLE_NAME="AmuxAIClean"

CLEAN=0
DO_BUILD=1
for arg in "$@"; do
    case "$arg" in
        --clean)    CLEAN=1 ;;
        --no-build) DO_BUILD=0 ;;
        -h|--help)
            sed -n '3,20p' "$0"
            exit 0 ;;
        *)
            echo "[run_debug] 未知参数：$arg" >&2
            exit 2 ;;
    esac
done

step() { printf "\n\033[1;36m[run_debug]\033[0m %s\n" "$*"; }

cd "$ROOT"

step "1) 杀光所有 ${APP_NAME} 进程"
pkill -9 -f "${APP_NAME}.app/Contents/MacOS/${EXECUTABLE_NAME}" 2>/dev/null || true
sleep 1
if pgrep -f "${APP_NAME}.app/Contents/MacOS/${EXECUTABLE_NAME}" >/dev/null; then
    echo "  仍有残留进程，再 kill 一次"
    pkill -9 -f "${APP_NAME}.app/Contents/MacOS/${EXECUTABLE_NAME}" 2>/dev/null || true
    sleep 1
fi
echo "  已无 ${APP_NAME} 进程"

if [ "$DO_BUILD" -eq 1 ]; then
    if [ "$CLEAN" -eq 1 ]; then
        step "2) xcodebuild clean"
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug clean 2>&1 | tail -3
    fi

    step "3) xcodebuild Debug 构建（签名走 .xcodeproj 里 Manual + Apple Distribution 企业证书）"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug build 2>&1 | tail -5
fi

step "4) 解析产物路径（xcodebuild -showBuildSettings）"
BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug -showBuildSettings 2>/dev/null)"
BUILT_PRODUCTS_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR =/{print $2; exit}')"
FULL_PRODUCT_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*FULL_PRODUCT_NAME =/{print $2; exit}')"
EXECUTABLE_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*EXECUTABLE_NAME =/{print $2; exit}')"
APP_NAME="${FULL_PRODUCT_NAME%.app}"
APP_PATH="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"

if [ ! -x "${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}" ]; then
    echo "[run_debug] 未找到产物：${APP_PATH}" >&2
    echo "[run_debug] 请先去掉 --no-build 让脚本帮你 build" >&2
    exit 3
fi

MTIME=$(stat -f "%Sm" "${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}")
echo "  产物：${APP_PATH}"
echo "  时间：${MTIME}"

step "5) 启动 ${FULL_PRODUCT_NAME}（绝对路径，绕开 LaunchServices 默认解析）"
open -n "$APP_PATH"
sleep 2

PID=$(pgrep -f "${APP_NAME}.app/Contents/MacOS/${EXECUTABLE_NAME}" | head -1 || true)
if [ -z "${PID}" ]; then
    echo "[run_debug] 启动后未发现进程，可能是 build 损坏或权限问题" >&2
    exit 4
fi

step "6) 拉到前台"
osascript -e "tell application \"${APP_NAME}\" to activate" 2>/dev/null || true
osascript -e "tell application \"System Events\" to tell process \"${APP_NAME}\" to set frontmost to true" 2>/dev/null || true

echo
echo "  PID: ${PID}"
echo "  完成。窗口应已置前。"
echo
echo "  停止：pkill -9 -f \"${APP_NAME}.app/Contents/MacOS/${EXECUTABLE_NAME}\""
