#!/usr/bin/env bash
#
# Debug 一键运行
#
# 做了什么：
#   1. 杀光所有正在跑的 GSYCleanMac 进程（避免老版本残留）
#   2. xcodebuild Debug ad-hoc 签名增量 build
#   3. 从 DerivedData 唯一产物路径启动 .app（绕开 LaunchServices 缓存）
#   4. activate 到前台
#
# 用法：
#   ./Scripts/run_debug.sh                # 增量 build + 启动
#   ./Scripts/run_debug.sh --clean        # clean 后再 build + 启动
#   ./Scripts/run_debug.sh --no-build     # 只启动，不 build
#
# 解决了什么坑：
#   - 系统里历史上注册过多个 GSYCleanMac.app 路径（build/dd build/release dist
#     build/debug DerivedData 等），LaunchServices 数据库会按优先级随机挑一个，
#     直接 `open -a GSYCleanMac` 可能跳到老二进制，让你以为"代码改了但没生效"。
#     这个脚本始终从 DerivedData 那一条**绝对路径**启动，杜绝歧义。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="GSYCleanMac"
APP_PATH="${HOME}/Library/Developer/Xcode/DerivedData/GSYCleanMac-dsitrkqztcjxjkawutocbbdsrckt/Build/Products/Debug/${SCHEME}.app"

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

step "1) 杀光所有 GSYCleanMac 进程"
pkill -9 -f "${SCHEME}.app/Contents/MacOS/${SCHEME}" 2>/dev/null || true
sleep 1
if pgrep -f "${SCHEME}.app/Contents/MacOS/${SCHEME}" >/dev/null; then
    echo "  仍有残留进程，再 kill 一次"
    pkill -9 -f "${SCHEME}.app/Contents/MacOS/${SCHEME}" 2>/dev/null || true
    sleep 1
fi
echo "  已无 ${SCHEME} 进程"

if [ "$DO_BUILD" -eq 1 ]; then
    if [ "$CLEAN" -eq 1 ]; then
        step "2) xcodebuild clean"
        xcodebuild -scheme "$SCHEME" -configuration Debug clean 2>&1 | tail -3
    fi

    # 签名身份决议：
    #   1) 优先环境变量 GSYCLEAN_CODESIGN_IDENTITY（由 ./Scripts/setup_codesign.sh 产出，
    #      指向钥匙串里的 "GSYCleanMac Local Dev" 自签名证书 SHA-1）
    #   2) 否则若钥匙串能直接按 CN 找到该证书也用它（用户跑过 setup_codesign.sh
    #      但当前 shell 没 source 环境变量的情况）
    #   3) 否则 fallback ad-hoc "-"
    #
    # 这是修 bug3 "每次都要重新授权完全磁盘访问" 的关键——
    # ad-hoc 签每次重 build cdhash 都变，TCC 把它当新 App 反复要权限；
    # 用稳定本地证书签后 cdhash 稳定，TCC 授权一次就长期记住。
    LOCAL_CN="GSYCleanMac Local Dev"
    SIGN_IDENTITY=""
    if [ -n "${GSYCLEAN_CODESIGN_IDENTITY:-}" ]; then
        SIGN_IDENTITY="$GSYCLEAN_CODESIGN_IDENTITY"
        echo "[run_debug] 使用环境变量 GSYCLEAN_CODESIGN_IDENTITY 签名"
    elif security find-identity -v -p codesigning login.keychain 2>/dev/null | grep -q "$LOCAL_CN"; then
        SIGN_IDENTITY="$LOCAL_CN"
        echo "[run_debug] 钥匙串里有 \"$LOCAL_CN\"，用它签名（建议把 GSYCLEAN_CODESIGN_IDENTITY 加到 ~/.zshrc）"
    else
        SIGN_IDENTITY="-"
        echo "[run_debug] 未找到本地稳定签名身份，使用 ad-hoc \"-\""
        echo "[run_debug] 提示：跑一次 ./Scripts/setup_codesign.sh 可根治"
        echo "[run_debug]       「每次启动都要重新授权完全磁盘访问」 的问题"
    fi

    step "3) xcodebuild Debug 构建（签名身份：${SIGN_IDENTITY}）"
    if [ "$SIGN_IDENTITY" = "-" ]; then
        xcodebuild -scheme "$SCHEME" -configuration Debug \
            CODE_SIGN_IDENTITY="-" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGNING_REQUIRED=NO \
            CODE_SIGNING_ALLOWED=NO \
            build 2>&1 | tail -3
    else
        xcodebuild -scheme "$SCHEME" -configuration Debug \
            CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
            CODE_SIGN_STYLE=Manual \
            CODE_SIGNING_REQUIRED=YES \
            CODE_SIGNING_ALLOWED=YES \
            build 2>&1 | tail -3
    fi
fi

if [ ! -x "${APP_PATH}/Contents/MacOS/${SCHEME}" ]; then
    echo "[run_debug] 未找到产物：${APP_PATH}" >&2
    echo "[run_debug] 请先去掉 --no-build 让脚本帮你 build" >&2
    exit 3
fi

MTIME=$(stat -f "%Sm" "${APP_PATH}/Contents/MacOS/${SCHEME}")
echo "  产物：${APP_PATH}"
echo "  时间：${MTIME}"

step "4) 启动 ${SCHEME}.app（绝对路径，绕开 LaunchServices 默认解析）"
open -n "$APP_PATH"
sleep 2

PID=$(pgrep -f "${SCHEME}.app/Contents/MacOS/${SCHEME}" | head -1 || true)
if [ -z "${PID}" ]; then
    echo "[run_debug] 启动后未发现进程，可能是 build 损坏或权限问题" >&2
    exit 4
fi

step "5) 拉到前台"
osascript -e "tell application \"${SCHEME}\" to activate" 2>/dev/null || true
osascript -e "tell application \"System Events\" to tell process \"${SCHEME}\" to set frontmost to true" 2>/dev/null || true

echo
echo "  PID: ${PID}"
echo "  完成。窗口应已置前。"
echo
echo "  停止：pkill -9 -f \"${SCHEME}.app/Contents/MacOS/${SCHEME}\""
