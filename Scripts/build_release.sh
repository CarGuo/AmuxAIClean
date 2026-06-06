#!/usr/bin/env bash
# build_release.sh —— GSYCleanMac Release 打包
#
# 用法:
#   ./Scripts/build_release.sh                 # 默认：Release 配置 + .xcodeproj 里的签名设置
#   VERSION=1.0.0 ./Scripts/build_release.sh   # 指定版本号写进 Info.plist 与 dmg 文件名
#
# 设计原则（Step 5.6 番外回归 Xcode 原生路径）：
#   - 不再做签名身份决议；签名完全由 .xcodeproj 里的 Automatic + Personal Team 决定
#   - 不再调用 xcodegen；.xcodeproj 已入仓
#   - Personal Team 签出来的 Apple Development 证书签 .app 仅本机能跑；
#     如要分发到其它机器需切 Developer ID 公证（见 Scripts/codesign.sh + docs/RELEASE.md）

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="GSYCleanMac"
SCHEME="GSYCleanMac"
PROJECT="${ROOT}/${PROJECT_NAME}.xcodeproj"
CONFIG="${CONFIG:-Release}"
VERSION="${VERSION:-}"
BUILD_DIR="${BUILD_DIR:-${ROOT}/build/release}"
DIST_DIR="${DIST_DIR:-${ROOT}/dist}"

if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi
step() { printf "${BOLD}${GREEN}==>${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}!! %s${NC}\n" "$*" >&2; }
fail() { printf "${RED}xx %s${NC}\n" "$*" >&2; exit 1; }

cd "$ROOT"

step "检查 xcodebuild 与 .xcodeproj"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild 未找到，请安装 Xcode 16+"
[ -d "$PROJECT" ] || fail ".xcodeproj 不在：$PROJECT"

step "清理旧 ${BUILD_DIR}/Build/Products/${CONFIG}/${PROJECT_NAME}.app 与 ${DIST_DIR}/${PROJECT_NAME}.app"
rm -rf "$BUILD_DIR/Build/Products/${CONFIG}/${PROJECT_NAME}.app"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/${PROJECT_NAME}.app"

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

xcodebuild "${XCB_ARGS[@]}" | xcbeautify 2>/dev/null || \
  xcodebuild "${XCB_ARGS[@]}" 2>&1 | tail -100

APP_PATH="$BUILD_DIR/Build/Products/${CONFIG}/${PROJECT_NAME}.app"
[ -d "$APP_PATH" ] || fail "构建产物未生成：$APP_PATH"

step "复制产物到 ${DIST_DIR}/${PROJECT_NAME}.app"
ditto "$APP_PATH" "$DIST_DIR/${PROJECT_NAME}.app"

step "校验 codesign"
codesign -dv --verbose=2 "$DIST_DIR/${PROJECT_NAME}.app" 2>&1 | head -8 || true

# v1.5.7：核对 Hardened Runtime 是否开启
# 本地 Personal Team 走 .xcodeproj 里的 ENABLE_HARDENED_RUNTIME = YES；如果设置被改回 NO 这里会 warn
# ad-hoc 签名: flags=0x10002(adhoc,runtime); Developer ID: flags=0x10000(runtime); Personal Team 又不同
# 用正则匹配括号内出现 runtime, 兼容三种签名身份
# 注意: 先缓存到变量再 grep, 不能 codesign | grep -q —— -q 提前 quit 在 pipefail 下让上游收 SIGPIPE 误报失败
CS_OUT=$(codesign -d -vvv "$DIST_DIR/${PROJECT_NAME}.app" 2>&1 || true)
if echo "$CS_OUT" | grep -Eq "flags=0x[0-9a-fA-F]+\([^)]*runtime"; then
    echo "  ✓ Hardened Runtime: enabled"
else
    warn "Hardened Runtime 未启用（codesign flags 未含 runtime）；建议 .xcodeproj 设 ENABLE_HARDENED_RUNTIME=YES"
fi

step "校验 Info.plist 版本一致性"
PLIST="$DIST_DIR/${PROJECT_NAME}.app/Contents/Info.plist"
ACTUAL_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "?")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo "?")
echo "  CFBundleShortVersionString = ${ACTUAL_SHORT}"
echo "  CFBundleVersion            = ${ACTUAL_BUILD}"
if [ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]; then
    warn "CFBundleVersion 写入失败（期望 ${BUILD_NUMBER}，实际 ${ACTUAL_BUILD}），Sparkle 升级可能异常"
fi

cat <<EOF

${GREEN}${BOLD}Release 构建完成${NC}
  配置:       ${CONFIG}
  版本:       ${VERSION:-${ACTUAL_SHORT}}
  Build:      ${BUILD_NUMBER} (git ${GIT_SHA})
  产物:       ${DIST_DIR}/${PROJECT_NAME}.app
  签名:       走 .xcodeproj 里 Xcode UI 配的 Personal Team Automatic
              （要分发到其它机器需 Developer ID 公证，见 Scripts/codesign.sh）

下一步：
  ./Scripts/make_dmg.sh ${DIST_DIR}/${PROJECT_NAME}.app ${DIST_DIR}/${PROJECT_NAME}-${VERSION:-1.0.0}.dmg

EOF
