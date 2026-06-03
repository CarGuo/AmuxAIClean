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
XCB_ARGS=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$CONFIG"
    -derivedDataPath "$BUILD_DIR"
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

cat <<EOF

${GREEN}${BOLD}Release 构建完成${NC}
  配置:   ${CONFIG}
  版本:   ${VERSION:-（默认沿用 Info.plist 的 CFBundleShortVersionString）}
  产物:   ${DIST_DIR}/${PROJECT_NAME}.app
  签名:   走 .xcodeproj 里 Xcode UI 配的 Personal Team Automatic
          （要分发到其它机器需 Developer ID 公证，见 Scripts/codesign.sh）

下一步：
  ./Scripts/make_dmg.sh ${DIST_DIR}/${PROJECT_NAME}.app ${DIST_DIR}/${PROJECT_NAME}-${VERSION:-1.0.0}.dmg

EOF
