#!/usr/bin/env bash
# 一次性 AX 树探测：启动 Debug .app → 等主窗口 → osascript dump → graceful quit
# 用途：为 Scripts/e2e/ 的所有 flow 提供可点按钮清单基线
# 输入：无（自动定位 Debug .app）
# 输出：Scripts/e2e/ax-dump-baseline.txt

set -u -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$REPO_ROOT/Scripts/e2e/ax-dump-baseline.txt"
PROC_NAME="AmuxAIClean"
BUNDLE_ID="com.amux.ai.Clean"

DD="$(xcodebuild -project "$REPO_ROOT/GSYCleanMac.xcodeproj" -scheme GSYCleanMac -configuration Debug -showBuildSettings 2>/dev/null | grep -E '^\s+BUILT_PRODUCTS_DIR' | head -1 | awk -F'= ' '{print $2}')"
APP="$DD/AmuxAIClean.app"
APP_BIN="$APP/Contents/MacOS/AmuxAIClean"

if [ ! -x "$APP_BIN" ]; then
    echo "❌ 未找到 Debug .app（$APP_BIN）；请先跑 xcodebuild build" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
: > "$OUT"

log() { echo "[ax-probe $(date +%H:%M:%S)] $*"; }

log "PROBE STEP 1: kill 残留"
pkill -9 -f "$APP_BIN" 2>/dev/null || true
sleep 1

log "PROBE STEP 2: 启动 App"
"$APP_BIN" >/tmp/ax-probe-runtime.log 2>&1 &
APP_PID=$!
log "  pid=$APP_PID"

log "PROBE STEP 3: 等主窗口就绪（最多 15s）"
READY=0
for i in $(seq 1 15); do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "  ❌ App 在 ${i}s 内退出，见 /tmp/ax-probe-runtime.log"
        tail -30 /tmp/ax-probe-runtime.log
        exit 2
    fi
    WC="$(osascript -e "tell application \"System Events\" to tell process \"$PROC_NAME\" to count windows" 2>/dev/null || echo 0)"
    if [ "$WC" -ge 1 ] 2>/dev/null; then
        READY=1
        log "  ✅ 主窗口就绪 at t+${i}s"
        break
    fi
done

if [ "$READY" -ne 1 ]; then
    log "  ⚠️  未检测到窗口，但继续尝试 dump"
fi

log "PROBE STEP 4: dump AX 树 → $OUT"
{
    echo "# AmuxAIClean AX 树基线"
    echo "# 生成时间：$(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Debug .app: $APP"
    echo "#"
    echo "# 说明：本文件是 Scripts/e2e/ UI 自动化的按钮定位基线。"
    echo "# 每次 App UI 大改后应重新跑本脚本，diff 输出以感知控件变化。"
    echo ""
} >> "$OUT"

osascript 2>&1 <<OSA | tee -a "$OUT"
tell application "System Events"
    tell process "$PROC_NAME"
        set output to {}
        try
            set fe to value of attribute "AXFrontmost"
            set end of output to "frontmost=" & fe
        end try
        try
            set wc to count windows
            set end of output to "window_count=" & wc
        end try
        set winIdx to 0
        repeat with w in windows
            set winIdx to winIdx + 1
            set end of output to ""
            set end of output to "=== WINDOW " & winIdx & " ==="
            try
                set end of output to "  title=" & (title of w)
            end try
            try
                set end of output to "  subrole=" & (subrole of w)
            end try
            try
                set btnCount to count buttons of w
                set end of output to "  buttons=" & btnCount
                set bIdx to 0
                repeat with btn in buttons of w
                    set bIdx to bIdx + 1
                    set btnTitle to ""
                    set btnDesc to ""
                    set btnHelp to ""
                    try
                        set btnTitle to title of btn
                    end try
                    try
                        set btnDesc to description of btn
                    end try
                    try
                        set btnHelp to help of btn
                    end try
                    set end of output to "    button[" & bIdx & "] title=\"" & btnTitle & "\" desc=\"" & btnDesc & "\" help=\"" & btnHelp & "\""
                end repeat
            end try
            try
                set tabCount to count tab groups of w
                set end of output to "  tab_groups=" & tabCount
            end try
            try
                set stCount to count static texts of w
                set end of output to "  static_texts=" & stCount
                set stIdx to 0
                repeat with staticTextEl in static texts of w
                    set stIdx to stIdx + 1
                    if stIdx > 15 then exit repeat
                    try
                        set end of output to "    text[" & stIdx & "]=\"" & (value of staticTextEl) & "\""
                    end try
                end repeat
            end try
            try
                set tblCount to count tables of w
                set end of output to "  tables=" & tblCount
            end try
            try
                set olCount to count outlines of w
                set end of output to "  outlines=" & olCount
            end try
            try
                set grpCount to count groups of w
                set end of output to "  groups=" & grpCount
            end try
        end repeat
        try
            set mb to menu bar 1
            set end of output to ""
            set end of output to "=== MENU BAR ==="
            set mbiCount to count menu bar items of mb
            set end of output to "  menu_bar_items=" & mbiCount
            repeat with mbi in menu bar items of mb
                try
                    set end of output to "    menu=\"" & (title of mbi) & "\""
                end try
            end repeat
        end try
        set AppleScript's text item delimiters to linefeed
        return output as text
    end tell
end tell
OSA

log "PROBE STEP 5: graceful quit"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true

for i in $(seq 1 10); do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "  ✅ 已退出 at t+${i}s"
        break
    fi
done
if kill -0 "$APP_PID" 2>/dev/null; then
    log "  ⚠️  quit 无效，SIGTERM"
    kill -TERM "$APP_PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$APP_PID" 2>/dev/null || true
fi

wait "$APP_PID" 2>/dev/null || true

log "PROBE DONE：基线写入 $OUT"
echo ""
echo "== 前 60 行预览 =="
head -60 "$OUT"
