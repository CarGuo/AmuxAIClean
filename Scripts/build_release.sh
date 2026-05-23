#!/usr/bin/env bash
# build_release.sh —— GSYCleanMac Release 打包（自用 / 开源信任安装路径）
#
# 用法:
#   ./Scripts/build_release.sh                 # 默认：Release 配置 + 自动选签名 + 复制到 dist/
#   VERSION=1.0.0 ./Scripts/build_release.sh   # 指定版本号写进 Info.plist 与 dmg 文件名
#   IDENTITY="Developer ID..." ./Scripts/build_release.sh   # 显式覆盖签名身份
#
# 签名身份选择优先级（从高到低）：
#   1. 命令行 IDENTITY=...                    显式覆盖
#   2. 环境变量 GSYCLEAN_CODESIGN_IDENTITY    setup_codesign.sh 产出的本地稳定身份（推荐）
#   3. ad-hoc "-"                             零依赖兜底，但 TCC 授权会随每次重签失效
#
# 行为:
#   1. 若环境无 xcodeproj，自动 xcodegen generate
#   2. xcodebuild -configuration Release，可选注入 MARKETING_VERSION
#   3. 按上述优先级挑签名身份；非 ad-hoc 时 CODE_SIGNING_REQUIRED/ALLOWED 都打开
#   4. 输出产物到 dist/GSYCleanMac.app（保留原始 build 路径不动）
#
# 设计原则:
#   - 默认零依赖（仅需 xcodegen + xcodebuild）
#   - 幂等：重复运行覆盖产物不留垃圾
#   - 失败立即退出，便于 CI 抓取错误码

set -euo pipefail

PROJECT_NAME="GSYCleanMac"
SCHEME="GSYCleanMac"
CONFIG="${CONFIG:-Release}"
VERSION="${VERSION:-}"
# 签名身份优先级：命令行 IDENTITY > 环境变量 GSYCLEAN_CODESIGN_IDENTITY > ad-hoc "-"
IDENTITY="${IDENTITY:-${GSYCLEAN_CODESIGN_IDENTITY:--}}"
BUILD_DIR="${BUILD_DIR:-build/release}"
DIST_DIR="${DIST_DIR:-dist}"

# ----- 颜色辅助 -----
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi
step() { printf "${BOLD}${GREEN}==>${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}!! %s${NC}\n" "$*" >&2; }
fail() { printf "${RED}xx %s${NC}\n" "$*" >&2; exit 1; }

# ----- 1. 依赖检查 -----
step "检查 xcodebuild / xcodegen"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild 未找到，请安装 Xcode 16+"
command -v xcodegen   >/dev/null 2>&1 || fail "xcodegen 未找到：brew install xcodegen"

# ----- 2. xcodeproj 不在则生成 -----
if [ ! -d "${PROJECT_NAME}.xcodeproj" ]; then
  step "未发现 ${PROJECT_NAME}.xcodeproj，调用 xcodegen 生成"
  xcodegen generate
fi

# ----- 3. 清理旧 Release 产物 -----
step "清理旧 build/release 与 dist/${PROJECT_NAME}.app"
rm -rf "$BUILD_DIR/Build/Products/${CONFIG}/${PROJECT_NAME}.app"
mkdir -p "$DIST_DIR"
rm -rf "$DIST_DIR/${PROJECT_NAME}.app"

# ----- 4. 构建 -----
if [ "$IDENTITY" = "-" ]; then
  step "xcodebuild -scheme ${SCHEME} -configuration ${CONFIG}（ad-hoc 签名）"
  XCB_ARGS=(
    -scheme "$SCHEME"
    -configuration "$CONFIG"
    -derivedDataPath "$BUILD_DIR"
    CODE_SIGN_IDENTITY="$IDENTITY"
    CODE_SIGN_STYLE=Manual
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
    build
  )
else
  step "xcodebuild -scheme ${SCHEME} -configuration ${CONFIG}（身份：${IDENTITY}）"
  XCB_ARGS=(
    -scheme "$SCHEME"
    -configuration "$CONFIG"
    -derivedDataPath "$BUILD_DIR"
    CODE_SIGN_IDENTITY="$IDENTITY"
    CODE_SIGN_STYLE=Manual
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGNING_ALLOWED=YES
    build
  )
fi

if [ -n "$VERSION" ]; then
  XCB_ARGS=(MARKETING_VERSION="$VERSION" "${XCB_ARGS[@]}")
fi

xcodebuild "${XCB_ARGS[@]}" | xcbeautify 2>/dev/null || \
  xcodebuild "${XCB_ARGS[@]}" 2>&1 | tail -100

APP_PATH="$BUILD_DIR/Build/Products/${CONFIG}/${PROJECT_NAME}.app"
[ -d "$APP_PATH" ] || fail "构建产物未生成：$APP_PATH"

# ----- 5. 复制到 dist -----
step "复制产物到 ${DIST_DIR}/${PROJECT_NAME}.app"
ditto "$APP_PATH" "$DIST_DIR/${PROJECT_NAME}.app"

# ----- 6. 校验签名 -----
step "校验 codesign"
codesign -dv --verbose=2 "$DIST_DIR/${PROJECT_NAME}.app" 2>&1 | head -8 || true

cat <<EOF

${GREEN}${BOLD}Release 构建完成${NC}
  配置:   ${CONFIG}
  版本:   ${VERSION:-（默认沿用 project.yml 的 CFBundleShortVersionString）}
  签名:   ${IDENTITY}（- = ad-hoc 兜底；本地稳定身份请先跑 ./Scripts/setup_codesign.sh）
  产物:   ${DIST_DIR}/${PROJECT_NAME}.app

下一步：
  ./Scripts/make_dmg.sh ${DIST_DIR}/${PROJECT_NAME}.app ${DIST_DIR}/${PROJECT_NAME}-${VERSION:-1.0.0}.dmg

EOF
