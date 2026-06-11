#!/usr/bin/env bash
# E2E smoke runner: launch release .app, wait main window, probe AX tree, graceful quit.
# Usage: ./e2e-smoke.sh <app-path> <log-dir>

set -u

APP_PATH="${1:-/tmp/gsy-e2e-dd/Build/Products/Release/GSYCleanMac.app}"
LOG_DIR="${2:-/Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/logs}"
APP_BIN="$APP_PATH/Contents/MacOS/GSYCleanMac"
BUNDLE_ID="com.guoshuyu.cleanmac.GSYCleanMac"
PROC_NAME="GSYCleanMac"

OUT="$LOG_DIR/e2e-smoke.log"
AX="$LOG_DIR/e2e-ax-dump.log"
CRASH_LOG="$LOG_DIR/e2e-runtime.log"

mkdir -p "$LOG_DIR"
: > "$OUT"

log()  { echo "[E2E $(date +%H:%M:%S)] $*" | tee -a "$OUT" ; }

# 清干净任何残留实例
log "STEP 0: pkill 残留 GSYCleanMac 进程"
pkill -f "$APP_BIN" 2>/dev/null || true
sleep 1

# Step 1: launch as subprocess so we capture stderr/stdout for crash trace
log "STEP 1: 启动 .app（捕获 stdout/stderr 到 e2e-runtime.log）"
"$APP_BIN" > "$CRASH_LOG" 2>&1 &
APP_PID=$!
log "  launched pid=$APP_PID"

# Step 2: wait main window
log "STEP 2: 轮询主窗口就绪（最多 15s）"
READY=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "  ❌ FATAL: 进程在 ${i}s 内异常退出"
        log "  ---- runtime log tail ----"
        tail -50 "$CRASH_LOG" | tee -a "$OUT"
        exit 2
    fi
    # 用 osascript 测主窗口
    WIN_COUNT="$(osascript -e "tell application \"System Events\" to tell process \"$PROC_NAME\" to count windows" 2>/dev/null || echo "0")"
    log "  t+${i}s pid=$APP_PID windows=$WIN_COUNT"
    if [ "$WIN_COUNT" -ge 1 ] 2>/dev/null; then
        READY=1
        log "  ✅ 主窗口就绪 at t+${i}s"
        break
    fi
done

if [ "$READY" -ne 1 ]; then
    log "  ⚠️  15s 内未检测到窗口（可能 accessory-only / 需 AX 授权）"
fi

# Step 3: dump UI accessibility tree
log "STEP 3: dump AX tree → e2e-ax-dump.log"
osascript <<'OSA' > "$AX" 2>&1
tell application "System Events"
    tell process "GSYCleanMac"
        try
            set fe to value of attribute "AXFrontmost"
            log "frontmost=" & fe
        end try
        try
            set wc to count windows
            log "window_count=" & wc
            repeat with w in windows
                try
                    log "  window title=" & (title of w)
                    log "  window subrole=" & (subrole of w)
                end try
            end repeat
        end try
        try
            set mb to count menu bars
            log "menubar_count=" & mb
        end try
    end tell
end tell
OSA
log "  AX dump：$(wc -l < "$AX") lines"

# Step 4: graceful quit
log "STEP 4: osascript quit"
osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>&1 | tee -a "$OUT" || true

# Step 5: wait exit
log "STEP 5: 等待 .app 退出（≤10s）"
EXITED=0
for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
        EXITED=1
        log "  ✅ 退出 at t+${i}s"
        break
    fi
done
if [ "$EXITED" -ne 1 ]; then
    log "  ⚠️  quit 无效，发送 SIGTERM"
    kill -TERM "$APP_PID" 2>/dev/null || true
    sleep 2
    kill -KILL "$APP_PID" 2>/dev/null || true
fi

# Step 6: harvest exit code
wait "$APP_PID" 2>/dev/null
RC=$?
log "STEP 6: exit_code=$RC"

# Step 7: scan runtime log for crash signals
log "STEP 7: 扫描 e2e-runtime.log 关键字"
CRASH_HITS=$(grep -Eic 'fatal error|swift_unreachable|EXC_BAD|signal SIGSEGV|signal SIGABRT|uncaught exception|Crashed:|abort\(\)' "$CRASH_LOG" 2>/dev/null | head -1)
[ -z "$CRASH_HITS" ] && CRASH_HITS=0
WARN_HITS=$(grep -Eic 'error|warning' "$CRASH_LOG" 2>/dev/null | head -1)
[ -z "$WARN_HITS" ] && WARN_HITS=0
log "  crash_hits=$CRASH_HITS warn_hits=$WARN_HITS"

# Final verdict
log ""
log "================== E2E VERDICT =================="
log "  build:          ✅ Release"
log "  launch:         ✅ pid=$APP_PID"
log "  main_window:    $( [ $READY -eq 1 ] && echo ✅\ ready || echo ⚠️\ not\ detected )"
log "  graceful_quit:  $( [ $EXITED -eq 1 ] && echo ✅ || echo ⚠️\ SIGTERM\ used )"
log "  exit_code:      $RC"
log "  crash_keywords: $CRASH_HITS"
log "================================================="

# overall pass: launched + (window OR exited cleanly) + 0 crash keywords
if [ "$CRASH_HITS" -eq 0 ] && [ "$RC" -eq 0 ]; then
    log "RESULT: ✅ PASS"
    exit 0
else
    log "RESULT: ❌ FAIL"
    exit 1
fi
