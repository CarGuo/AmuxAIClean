#!/usr/bin/env bash
#
# Screenshot 自动化
#
# 做了什么：
#   1. 用 ./Scripts/run_debug.sh 起一个干净的 Debug 实例
#   2. 用 osascript 把 GSYCleanMac 拉到前台，逐个切到 4 个目标场景
#   3. 用 screencapture 把对应窗口截到 docs/screenshots/
#
# 输出（覆写）：
#   docs/screenshots/v1.4-overview.png        主窗口 + 推荐扫描结果
#   docs/screenshots/v1.4-dev-artifacts.png   开发者构建产物扫描结果
#   docs/screenshots/v1.4-hud-tray.png        灵动岛 HUD + 状态栏托盘
#   docs/screenshots/v1.4-settings-dev.png    设置面板「开发者扫描规则」Tab
#
# 前置条件（只配一次）：
#   - 系统设置 → 隐私与安全 → 屏幕录制 → 勾选 Terminal / iTerm
#   - 系统设置 → 隐私与安全 → 辅助功能 → 勾选 Terminal / iTerm
#   - 系统设置 → 隐私与安全 → 完全磁盘访问 → 勾选 GSYCleanMac
#     （后者为了让推荐扫描真的能跑出非空结果）
#
# 用法：
#   ./Scripts/screenshots.sh                 # 全套 4 张
#   ./Scripts/screenshots.sh overview        # 只截一张
#   ./Scripts/screenshots.sh --no-build      # 用现有 build，不重新编
#
# 已知坑：
#   - HUD 是个 floating panel，screencapture 默认只能截"主窗口列表"里
#     的窗口；脚本对 HUD 走 `screencapture -R <region>` 直接抓屏幕区域。
#   - 状态栏托盘图标坐标随屏幕宽度不同而不同，自动化抓不准；脚本用
#     "全屏截图后裁右上角"的兜底方案，再用 sips 切到 800x80 长条。
#   - 不同 macOS 版本下 osascript 关键字大小写、菜单标题翻译都会变，
#     失败时脚本会跳过该场景而非整体崩。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="GSYCleanMac"
OUT_DIR="${ROOT}/docs/screenshots"

mkdir -p "$OUT_DIR"

DO_BUILD=1
TARGETS=("overview" "dev-artifacts" "hud-tray" "settings-dev")

if [ $# -gt 0 ]; then
    TARGETS=()
    for arg in "$@"; do
        case "$arg" in
            --no-build) DO_BUILD=0 ;;
            overview|dev-artifacts|hud-tray|settings-dev) TARGETS+=("$arg") ;;
            -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
            *) echo "[screenshots] 未知参数：$arg" >&2; exit 2 ;;
        esac
    done
    if [ ${#TARGETS[@]} -eq 0 ]; then
        TARGETS=("overview" "dev-artifacts" "hud-tray" "settings-dev")
    fi
fi

step() { printf "\n\033[1;36m[screenshots]\033[0m %s\n" "$*"; }
note() { printf "\033[1;33m[screenshots]\033[0m %s\n" "$*"; }

step "1) 起 Debug 实例"
if [ "$DO_BUILD" -eq 1 ]; then
    "${ROOT}/Scripts/run_debug.sh" >/dev/null
else
    "${ROOT}/Scripts/run_debug.sh" --no-build >/dev/null
fi
sleep 2

activate() {
    osascript -e "tell application \"${SCHEME}\" to activate" >/dev/null 2>&1 || true
    osascript -e "tell application \"System Events\" to tell process \"${SCHEME}\" to set frontmost to true" >/dev/null 2>&1 || true
    sleep 1
}

# 找主窗口 ID（screencapture -l 接受的 windowID）
main_window_id() {
    osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
    tell process "GSYCleanMac"
        set winList to every window
        if (count of winList) is 0 then return ""
        return id of (first window whose subrole is "AXStandardWindow")
    end tell
end tell
OSA
}

capture_main_window() {
    local out="$1"
    local wid
    wid="$(main_window_id || true)"
    if [ -n "${wid:-}" ]; then
        screencapture -l "$wid" -o -x "$out"
    else
        note "没拿到主窗口 ID，退化为全屏截图"
        screencapture -o -x "$out"
    fi
}

# 在主窗口里点击侧栏分类（用 AX 索引）
click_sidebar_row() {
    local idx="$1"
    osascript <<OSA 2>/dev/null || true
tell application "System Events"
    tell process "GSYCleanMac"
        try
            tell first window
                tell first outline of first scroll area
                    select row $idx
                end tell
            end tell
        end try
    end tell
end tell
OSA
    sleep 1
}

# 打开设置窗口（Cmd+,）
open_settings() {
    osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
    tell process "GSYCleanMac"
        keystroke "," using {command down}
    end tell
end tell
OSA
    sleep 2
}

shoot_overview() {
    step "2.1 主窗口 + 推荐扫描"
    activate
    # 默认就是推荐扫描视图；多等点时间让 SafetyEngine 跑完
    sleep 3
    capture_main_window "${OUT_DIR}/v1.4-overview.png"
    echo "  -> ${OUT_DIR}/v1.4-overview.png"
}

shoot_dev_artifacts() {
    step "2.2 开发者构建产物扫描"
    activate
    # 侧栏第几行是 "开发者构建产物" 取决于本地构建的分类顺序；
    # 默认顺序里它在 "整盘扫描" 之后；下面尝试索引 5 / 6 / 7。
    for idx in 5 6 7 4; do
        click_sidebar_row "$idx"
        sleep 2
    done
    sleep 2
    capture_main_window "${OUT_DIR}/v1.4-dev-artifacts.png"
    echo "  -> ${OUT_DIR}/v1.4-dev-artifacts.png"
    note "如果截图不是开发者扫描，请手动点该侧栏分类后再跑：./Scripts/screenshots.sh dev-artifacts --no-build"
}

shoot_hud_tray() {
    step "2.3 灵动岛 HUD + 状态栏托盘"
    activate
    # HUD 由托盘菜单 "悬浮 HUD" 触发；托盘图标点击坐标抓不到，
    # 退化为：直接全屏截图，要求用户点亮 HUD 后跑。
    note "请在 5 秒内点亮托盘 HUD（点状态栏 GSYCleanMac 图标 → 悬浮 HUD），然后保持鼠标不动..."
    sleep 5
    screencapture -o -x "${OUT_DIR}/v1.4-hud-tray.png"
    echo "  -> ${OUT_DIR}/v1.4-hud-tray.png"
}

shoot_settings_dev() {
    step "2.4 设置面板 - 开发者扫描规则"
    activate
    open_settings
    sleep 1
    # 设置 Tab 顺序：通用 / 推荐扫描 / 开发者扫描规则 / 安全保护 / 自动检查更新 / 关于
    osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
    tell process "GSYCleanMac"
        try
            click button 3 of toolbar 1 of window "Settings"
        on error
            try
                click button 3 of toolbar 1 of window 1
            end try
        end try
    end tell
end tell
OSA
    sleep 2
    # 设置窗口标题在中文环境是 "设置"，在英文是 "Settings"；都试一遍
    local wid
    wid="$(osascript <<'OSA' 2>/dev/null || true
tell application "System Events"
    tell process "GSYCleanMac"
        try
            return id of (first window whose name is "Settings" or name is "设置")
        end try
    end tell
end tell
OSA
)"
    if [ -n "${wid:-}" ]; then
        screencapture -l "$wid" -o -x "${OUT_DIR}/v1.4-settings-dev.png"
    else
        screencapture -o -x "${OUT_DIR}/v1.4-settings-dev.png"
    fi
    echo "  -> ${OUT_DIR}/v1.4-settings-dev.png"
}

for t in "${TARGETS[@]}"; do
    case "$t" in
        overview) shoot_overview ;;
        dev-artifacts) shoot_dev_artifacts ;;
        hud-tray) shoot_hud_tray ;;
        settings-dev) shoot_settings_dev ;;
    esac
done

step "完成。输出目录：${OUT_DIR}"
ls -la "${OUT_DIR}" | grep "v1\.4" || true
