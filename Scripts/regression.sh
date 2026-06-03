#!/usr/bin/env bash
#
# GSYCleanMac 真实场景回归测试一键脚本
#
# 设计目标：
#   - 跑真实 App 进程，不是 swift test mock
#   - 通过环境变量 GSY_REGRESSION_CASE=<case-id> 触发 RegressionRunner（见 App/GSYCleanMacApp.swift）
#   - 每条 case 通过 stderr 打 [REGR_BEGIN] / [REGR k=v] / [REGR_PASS|REGR_FAIL] 结构化日志
#   - exit(0) 表示 PASS，exit(1) 表示 FAIL
#   - 默认 90s 超时，单 case 超时即记 TIMEOUT（视为 FAIL）
#   - 所有 case log 写到 Tests/Regression/logs/<case>.log，结果汇总写 Tests/Regression/last-run.json
#
# 用法：
#   ./Scripts/regression.sh                      # 跑所有 19 个 case
#   ./Scripts/regression.sh --no-build           # 不重新 build，直接跑（适合反复调试单 case）
#   ./Scripts/regression.sh --only scan-custom-fixture,hud-toggle   # 只跑指定 case
#   ./Scripts/regression.sh --timeout 180        # 自定义单 case 超时秒数（默认 90）
#

set -e
set -o pipefail

# 在 run_case 与汇总段需要宽松：等待子进程退出码、grep 不到都不应中断
allow_fail() { set +e; }
strict()     { set -e; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="GSYCleanMac"
PROJECT="${ROOT}/${SCHEME}.xcodeproj"

# Step 5.6 番外：用 xcodebuild -showBuildSettings 动态查 BUILT_PRODUCTS_DIR，
# 取代旧 ~/Library/Developer/Xcode/DerivedData/GSYCleanMac-<hash>/... 硬编码
# （hash 由项目绝对路径派生，跨机器/移动目录后会变，硬编码不可移植）
APP_PATH="$(
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR =/{print $2; exit}'
)/${SCHEME}.app"
APP_BIN="${APP_PATH}/Contents/MacOS/${SCHEME}"
LOG_DIR="${ROOT}/Tests/Regression/logs"
RESULT_JSON="${ROOT}/Tests/Regression/last-run.json"

# 全部 19 条 case（顺序与 RegressionRunner.swift switch 保持一致）
ALL_CASES=(
    # 扫描核心 5
    "scan-custom-fixture"
    "scan-recommended"
    "tree-drilldown"
    "scan-cancel-restart"
    "large-files-threshold"
    # 结果加工 / 导出 6
    "duplicate-scan"
    "orphan-scan"
    "appfootprint-scan"
    "uninstaller-dryrun"
    "launchagent-scan"
    "exporter-csv"
    # UI / HUD / 托盘 / 激活策略 4
    "hud-toggle"
    "tray-install-uninstall"
    "activation-policy"
    "quicklook-controller"
    # 安全 / 删除 2（v1.3.zzzz 路线 B：helper-bridge-stub / deletion-token-roundtrip 随 Helper 整段下线）
    "trash-pipeline-dryrun"
    "safety-engine-veto"
    # 真实场景诊断 3
    "trash-real-scan"
    "fda-banner-diagnose"
    "scan-perf-diagnose"
)

# 部分 case 由于跑全盘真实扫描，需要更长超时（bash 3 兼容：用 case 函数）
case_timeout_for() {
    case "$1" in
        scan-recommended) echo 600 ;;
        fda-banner-diagnose) echo 600 ;;
        scan-perf-diagnose) echo 900 ;;
        *) echo "" ;;
    esac
}

DEFAULT_TIMEOUT=90
DO_BUILD=1
ONLY=""
USER_TIMEOUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build)  DO_BUILD=0; shift ;;
        --only)      ONLY="$2"; shift 2 ;;
        --timeout)   USER_TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,30p' "$0"
            exit 0 ;;
        *)
            echo "[regression] 未知参数：$1" >&2
            exit 2 ;;
    esac
done

step() { printf "\n\033[1;36m[regression]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m  ✓ %s\033[0m\n" "$*"; }
bad()  { printf "\033[1;31m  ✗ %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m  ! %s\033[0m\n" "$*"; }

mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$RESULT_JSON")"

# 选择跑哪些 case
CASES=()
if [ -n "$ONLY" ]; then
    IFS=',' read -ra REQ <<< "$ONLY"
    for r in "${REQ[@]}"; do
        found=0
        for c in "${ALL_CASES[@]}"; do
            if [ "$c" = "$r" ]; then CASES+=("$r"); found=1; break; fi
        done
        if [ $found -eq 0 ]; then
            echo "[regression] 未知 case：$r" >&2
            echo "[regression] 可用 case：${ALL_CASES[*]}" >&2
            exit 3
        fi
    done
else
    CASES=("${ALL_CASES[@]}")
fi

# 1) 杀掉所有残留进程
step "杀掉所有残留 ${SCHEME} 进程"
pkill -9 -f "${APP_BIN}" 2>/dev/null || true
sleep 1

# 2) Build（除非 --no-build）
if [ "$DO_BUILD" -eq 1 ]; then
    step "xcodebuild Debug 增量构建（签名走 .xcodeproj 里 Automatic + Personal Team）"
    if ! xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
            -destination 'platform=macOS' \
            -quiet build 2>&1 | tail -20; then
        bad "build 失败，终止"
        exit 4
    fi
    ok "build 完成"
fi

if [ ! -x "$APP_BIN" ]; then
    bad "找不到产物 $APP_BIN，请去掉 --no-build"
    exit 5
fi

# 3) 顺序跑每条 case
step "开始跑 ${#CASES[@]} 个 case（产物：$APP_BIN）"

PASS_LIST=()
FAIL_LIST=()
TIMEOUT_LIST=()
# bash 3 没有关联数组：用一个 tmp 目录存 elapsed/reason，键即文件名
META_DIR="$(mktemp -d /tmp/gsyclean-regression.XXXXXX)"
trap 'rm -rf "$META_DIR"' EXIT

put_elapsed() { printf '%s' "$2" > "$META_DIR/elapsed.$1"; }
get_elapsed() { [ -f "$META_DIR/elapsed.$1" ] && cat "$META_DIR/elapsed.$1" || echo 0; }
put_reason()  { printf '%s' "$2" > "$META_DIR/reason.$1"; }
get_reason()  { [ -f "$META_DIR/reason.$1" ] && cat "$META_DIR/reason.$1" || echo ""; }

run_case() {
    local cid="$1"
    local log="${LOG_DIR}/${cid}.log"
    local timeout_s=""
    if [ -n "$USER_TIMEOUT" ]; then
        timeout_s="$USER_TIMEOUT"
    else
        timeout_s="$(case_timeout_for "$cid")"
        [ -z "$timeout_s" ] && timeout_s="$DEFAULT_TIMEOUT"
    fi

    : > "$log"
    printf "  [%-32s] timeout=%ss ... " "$cid" "$timeout_s"

    # 启动 App 子进程：环境变量驱动 RegressionRunner
    # 注意：不能用 `open`（异步且不传 env），必须直接 exec 二进制
    GSY_REGRESSION_CASE="$cid" \
    GSY_AUTOSCAN="" \
    "$APP_BIN" >"$log" 2>&1 &
    local pid=$!

    # 等待，超时则 kill
    local waited=0
    local exitcode=""
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$timeout_s" ]; then
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            exitcode="TIMEOUT"
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done
    if [ -z "$exitcode" ]; then
        wait "$pid" 2>/dev/null
        exitcode=$?
    fi

    # 解析尾行
    local pass_line
    pass_line=$(grep -E '^\[REGR_(PASS|FAIL)\]' "$log" | tail -1 || true)
    local elapsed=""
    elapsed=$(printf '%s' "$pass_line" | sed -nE 's/.*elapsed_ms=([0-9]+).*/\1/p')
    [ -n "$elapsed" ] && put_elapsed "$cid" "$elapsed"

    if [ "$exitcode" = "TIMEOUT" ]; then
        TIMEOUT_LIST+=("$cid")
        put_reason "$cid" "timeout after ${timeout_s}s"
        printf "\033[1;33mTIMEOUT (%ss)\033[0m\n" "$timeout_s"
        return
    fi

    if [ "$exitcode" -eq 0 ] && printf '%s' "$pass_line" | grep -q '^\[REGR_PASS\]'; then
        PASS_LIST+=("$cid")
        printf "\033[1;32mPASS\033[0m  (%sms)\n" "$(get_elapsed "$cid")"
    else
        FAIL_LIST+=("$cid")
        local reason
        reason=$(printf '%s' "$pass_line" | sed -nE 's/.*reason=(.*)$/\1/p')
        if [ -z "$reason" ]; then
            reason="exit=$exitcode (no [REGR_PASS|REGR_FAIL] line; see $log)"
        fi
        put_reason "$cid" "$reason"
        printf "\033[1;31mFAIL\033[0m  (%s)\n" "$reason"
    fi
}

for c in "${CASES[@]}"; do
    allow_fail
    run_case "$c"
    strict
    # 每条 case 之间 kill 残留并 sleep 1s 让端口/资源释放
    pkill -9 -f "${APP_BIN}" 2>/dev/null || true
    sleep 1
done

# 4) 汇总
step "结果汇总"
total=${#CASES[@]}
pass=${#PASS_LIST[@]}
fail=${#FAIL_LIST[@]}
to=${#TIMEOUT_LIST[@]}
echo "  total=$total  PASS=$pass  FAIL=$fail  TIMEOUT=$to"
if [ "$fail" -gt 0 ]; then
    echo "  FAIL cases:"
    for c in "${FAIL_LIST[@]}"; do echo "    - $c  ::  $(get_reason "$c")"; done
fi
if [ "$to" -gt 0 ]; then
    echo "  TIMEOUT cases:"
    for c in "${TIMEOUT_LIST[@]}"; do echo "    - $c  ::  $(get_reason "$c")"; done
fi

# 5) 写 last-run.json
build_json() {
    local first=1
    printf '{\n'
    printf '  "ranAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "total": %d,\n' "$total"
    printf '  "pass": %d,\n' "$pass"
    printf '  "fail": %d,\n' "$fail"
    printf '  "timeout": %d,\n' "$to"
    printf '  "cases": [\n'
    for c in "${CASES[@]}"; do
        local status="UNKNOWN"
        for p in "${PASS_LIST[@]}"; do [ "$p" = "$c" ] && status="PASS"; done
        for p in "${FAIL_LIST[@]}"; do [ "$p" = "$c" ] && status="FAIL"; done
        for p in "${TIMEOUT_LIST[@]}"; do [ "$p" = "$c" ] && status="TIMEOUT"; done
        local reason="$(get_reason "$c")"
        local elapsed="$(get_elapsed "$c")"
        # 转义 reason 里的双引号
        reason_esc=$(printf '%s' "$reason" | sed 's/"/\\"/g')
        if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
        printf '    { "id": "%s", "status": "%s", "elapsedMs": %s, "reason": "%s" }' \
            "$c" "$status" "$elapsed" "$reason_esc"
    done
    printf '\n  ]\n}\n'
}

build_json > "$RESULT_JSON"
ok "汇总写入 $RESULT_JSON"
ok "单 case log 在 $LOG_DIR/<case>.log"

if [ "$fail" -gt 0 ] || [ "$to" -gt 0 ]; then
    exit 1
fi
exit 0
