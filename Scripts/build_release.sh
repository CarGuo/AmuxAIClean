#!/usr/bin/env bash
# build_release.sh —— AmuxAIClean Release 打包
#
# 用法:
#   ./Scripts/build_release.sh                 # 默认：Developer ID 签名 + DMG，不公证
#   ./Scripts/build_release.sh --notarize      # Developer ID 签名 + App/DMG 公证 + staple + Gatekeeper 校验
#   ./Scripts/build_release.sh --app-only      # 只构建 .app，不生成 DMG
#   VERSION=1.0.0 ./Scripts/build_release.sh   # 指定版本号写进 Info.plist 与产物文件名
#
# 设计原则（Step 5.6 番外回归 Xcode 原生路径）：
#   - 不再做签名身份决议；签名完全由 .xcodeproj 里的 Release Manual + Developer ID Application 决定
#   - 不再调用 xcodegen；.xcodeproj 已入仓
#   - 当前项目配置使用 Developer ID Application: SentenceEnd Inc (W6H34N9728)；
#     若要公网分发仍需补齐 notarization / stapling / Gatekeeper 校验。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="GSYCleanMac"
APP_NAME="AmuxAIClean"
SCHEME="GSYCleanMac"
PROJECT="${ROOT}/${PROJECT_NAME}.xcodeproj"
CONFIG="${CONFIG:-Release}"
VERSION="${VERSION:-}"
BUILD_DIR="${BUILD_DIR:-${ROOT}/build/release}"
DIST_DIR="${DIST_DIR:-${ROOT}/dist}"
NOTARY_PROFILE="${AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE:-${PASTE_MIND_NOTARY_KEYCHAIN_PROFILE:-${NOTARY_KEYCHAIN_PROFILE:-amux-notary}}}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-45m}"
MAKE_DMG=1
NOTARIZE=0
DMG_PATH="${DMG_PATH:-}"

if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi
step() { printf "${BOLD}${GREEN}==>${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}!! %s${NC}\n" "$*" >&2; }
fail() { printf "${RED}xx %s${NC}\n" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
用法: $0 [--notarize|--no-notarize] [--app-only]

模式:
  --no-notarize   默认。构建 Developer ID 签名 .app，并生成未公证 DMG
  --notarize      构建 .app，提交 App 与 DMG 到 Apple Notary，staple 后再校验
  --app-only      只构建 .app，不生成 DMG；可与 --no-notarize 一起用于快速验证

常用环境变量:
  VERSION=1.5.9
  BUILD_NUMBER=1234
  BUILD_DIR=build/release
  DIST_DIR=dist
  DMG_PATH=dist/AmuxAIClean-1.5.9.dmg
  AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary
  NOTARY_TIMEOUT=45m

示例:
  VERSION=1.5.9 $0 --no-notarize
  VERSION=1.5.9 AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary $0 --notarize
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --notarize)
      NOTARIZE=1
      MAKE_DMG=1
      ;;
    --no-notarize)
      NOTARIZE=0
      ;;
    --app-only)
      MAKE_DMG=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "未知参数：$1"
      ;;
  esac
  shift
done

notarize_file() {
  local file_path="$1"
  local label="$2"
  local submit_out submission_id

  command -v xcrun >/dev/null 2>&1 || fail "xcrun 未找到，无法调用 notarytool"
  [ -f "$file_path" ] || fail "待公证文件不存在：$file_path"

  step "提交 ${label} 到 Apple Notary（profile: ${NOTARY_PROFILE}, timeout: ${NOTARY_TIMEOUT}）"
  set +e
  submit_out="$(xcrun notarytool submit "$file_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --timeout "$NOTARY_TIMEOUT" 2>&1)"
  local status=$?
  set -e
  printf '%s\n' "$submit_out"

  submission_id="$(printf '%s\n' "$submit_out" | awk '/^[[:space:]]*id: /{print $2; exit}')"
  if [ "$status" -ne 0 ]; then
    if [ -n "$submission_id" ]; then
      warn "notarytool submit 失败，尝试读取 Apple Notary log：$submission_id"
      xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" || true
    fi
    fail "${label} 公证失败"
  fi

  if ! printf '%s\n' "$submit_out" | grep -q "status: Accepted"; then
    if [ -n "$submission_id" ]; then
      warn "Apple Notary 未返回 Accepted，尝试读取 log：$submission_id"
      xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" || true
    fi
    fail "${label} 公证未通过"
  fi
}

staple_file() {
  local file_path="$1"
  local label="$2"
  step "staple ${label}"
  xcrun stapler staple "$file_path"
  xcrun stapler validate "$file_path"
}

assess_app() {
  local app_path="$1"
  step "Gatekeeper 校验 App"
  spctl -a -vv -t exec "$app_path"
}

assess_dmg() {
  local dmg_path="$1"
  step "Gatekeeper 校验 DMG"
  spctl -a -vv -t open --context context:primary-signature "$dmg_path"
}

cd "$ROOT"

step "检查 xcodebuild 与 .xcodeproj"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild 未找到，请安装 Xcode 16+"
[ -d "$PROJECT" ] || fail ".xcodeproj 不在：$PROJECT"
if [ "$NOTARIZE" -eq 1 ]; then
    command -v xcrun >/dev/null 2>&1 || fail "xcrun 未找到，无法执行公证"
fi

step "清理旧 ${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}.app 与 ${DIST_DIR}/${APP_NAME}.app"
rm -rf "$BUILD_DIR/Build/Products/${CONFIG}/${APP_NAME}.app"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/${APP_NAME}.app"

step "xcodebuild -scheme ${SCHEME} -configuration ${CONFIG}"
# v1.5.7：CFBundleVersion 用 commit count 单调递增，保证每次构建唯一且可追溯。
# Sparkle / Apple App Store / Gatekeeper TCC 缓存均依赖 CFBundleVersion 判定是否"新版本"，
# 若多次 release 共用同一个 build 号会导致 update 静默失败、TCC 权限被错误复用。
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
step "Build number: ${BUILD_NUMBER} (git sha: ${GIT_SHA})"

XCB_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIG"
    -derivedDataPath "$BUILD_DIR"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    build
)
if [ -n "$VERSION" ]; then
    XCB_ARGS=(MARKETING_VERSION="$VERSION" "${XCB_ARGS[@]}")
fi

if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${XCB_ARGS[@]}" | xcbeautify
else
    xcodebuild "${XCB_ARGS[@]}"
fi

APP_PATH="$BUILD_DIR/Build/Products/${CONFIG}/${APP_NAME}.app"
[ -d "$APP_PATH" ] || fail "构建产物未生成：$APP_PATH"
DIST_APP_PATH="$DIST_DIR/${APP_NAME}.app"

step "复制产物到 ${DIST_APP_PATH}"
ditto "$APP_PATH" "$DIST_APP_PATH"

step "校验 codesign"
codesign --verify --strict --verbose=4 "$DIST_APP_PATH"
codesign -dv --verbose=2 "$DIST_APP_PATH" 2>&1 | head -8 || true

# v1.5.7：核对 Hardened Runtime 是否开启
# 本地 Personal Team 走 .xcodeproj 里的 ENABLE_HARDENED_RUNTIME = YES；如果设置被改回 NO 这里会 warn
# ad-hoc 签名: flags=0x10002(adhoc,runtime); Developer ID: flags=0x10000(runtime); Personal Team 又不同
# 用正则匹配括号内出现 runtime, 兼容三种签名身份
# 注意: 先缓存到变量再 grep, 不能 codesign | grep -q —— -q 提前 quit 在 pipefail 下让上游收 SIGPIPE 误报失败
CS_OUT=$(codesign -d -vvv "$DIST_APP_PATH" 2>&1 || true)
if echo "$CS_OUT" | grep -Eq "flags=0x[0-9a-fA-F]+\([^)]*runtime"; then
    echo "  ✓ Hardened Runtime: enabled"
else
    warn "Hardened Runtime 未启用（codesign flags 未含 runtime）；建议 .xcodeproj 设 ENABLE_HARDENED_RUNTIME=YES"
fi

step "校验 Info.plist 版本一致性"
PLIST="$DIST_APP_PATH/Contents/Info.plist"
ACTUAL_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "?")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo "?")
RELEASE_VERSION="${VERSION:-${ACTUAL_SHORT}}"
echo "  CFBundleShortVersionString = ${ACTUAL_SHORT}"
echo "  CFBundleVersion            = ${ACTUAL_BUILD}"
if [ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]; then
    warn "CFBundleVersion 写入失败（期望 ${BUILD_NUMBER}，实际 ${ACTUAL_BUILD}），Sparkle 升级可能异常"
fi

DMG_PATH="${DMG_PATH:-${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}.dmg}"
APP_NOTARY_ZIP="${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}-${BUILD_NUMBER}-app-notary.zip"

if [ "$NOTARIZE" -eq 1 ]; then
    step "准备 App 公证 zip"
    rm -f "$APP_NOTARY_ZIP"
    (cd "$DIST_DIR" && ditto -c -k --keepParent "${APP_NAME}.app" "$APP_NOTARY_ZIP")
    notarize_file "$APP_NOTARY_ZIP" "App bundle"
    staple_file "$DIST_APP_PATH" "App bundle"
    assess_app "$DIST_APP_PATH"
fi

if [ "$MAKE_DMG" -eq 1 ]; then
    step "生成 DMG：${DMG_PATH}"
    ./Scripts/make_dmg.sh "$DIST_APP_PATH" "$DMG_PATH"

    if [ "$NOTARIZE" -eq 1 ]; then
        notarize_file "$DMG_PATH" "DMG"
        staple_file "$DMG_PATH" "DMG"
        assess_dmg "$DMG_PATH"
    else
        warn "已生成未公证 DMG；只适合本地/内部快速验证，不等价于 Gatekeeper 公开分发闭环"
    fi
fi

cat <<EOF

${GREEN}${BOLD}Release 构建完成${NC}
  配置:       ${CONFIG}
  版本:       ${RELEASE_VERSION}
  Build:      ${BUILD_NUMBER} (git ${GIT_SHA})
  App:        ${DIST_APP_PATH}
  DMG:        $([ "$MAKE_DMG" -eq 1 ] && printf '%s' "$DMG_PATH" || printf '未生成 (--app-only)')
  签名:       走 .xcodeproj 里的 Release Manual + Developer ID Application
  公证:       $([ "$NOTARIZE" -eq 1 ] && printf '已提交 Apple Notary 并 staple' || printf '未公证')

EOF
