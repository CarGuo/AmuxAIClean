#!/usr/bin/env bash
# setup_dev.sh —— GSYCleanMac 新机器开发环境初始化
#
# 用法：
#   ./scripts/setup_dev.sh
#
# 行为：
#   1. 检查 macOS 版本（PITFALLS §1.2 锁 15+）
#   2. 检查 Xcode CLT / Xcode 是否已装
#   3. 安装 / 升级 Homebrew
#   4. 安装 xcodegen（项目 SOT 工程描述工具）
#   5. 提示 git clone（若当前不在仓库内）
#   6. 跑 xcodegen generate
#   7. open GSYCleanMac.xcodeproj
#
# 设计原则：每一步幂等，可重复执行不破坏环境

set -euo pipefail

REPO_URL="git@github.com:guoshuyu/GSYCleanMac.git"  # 占位，正式仓库地址 TBD
PROJECT_NAME="GSYCleanMac"
XCODEPROJ="GSYCleanMac.xcodeproj"
PROJECT_YML="project.yml"
MIN_MACOS_MAJOR=15

# ----- 颜色辅助 -----
if [ -t 1 ]; then
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  RED='\033[0;31m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi

step() { printf "${BOLD}${GREEN}==>${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}!! %s${NC}\n" "$*" >&2; }
fail() { printf "${RED}xx %s${NC}\n" "$*" >&2; exit 1; }

# ----- 1. macOS 版本检查 -----
step "检查 macOS 版本（要求 ${MIN_MACOS_MAJOR}+，PITFALLS §1.2）"
MACOS_VER="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VER%%.*}"
echo "    当前: macOS $MACOS_VER"
if [ "$MACOS_MAJOR" -lt "$MIN_MACOS_MAJOR" ]; then
  fail "macOS $MACOS_VER 低于最低要求 ${MIN_MACOS_MAJOR}.0；请升级到 Sequoia 或更高"
fi

# ----- 2. Xcode CLT -----
step "检查 Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode CLT 未安装；将弹出系统安装对话框"
  xcode-select --install || true
  echo "    完成后重新运行本脚本"
  exit 1
else
  echo "    已安装：$(xcode-select -p)"
fi

# ----- 3. Xcode 检查（编 Swift 6 需要 Xcode 16+） -----
step "检查 Xcode（Swift 6 toolchain 要求 Xcode 16+）"
if ! command -v xcodebuild >/dev/null 2>&1; then
  warn "未找到 xcodebuild —— 请从 App Store 安装 Xcode 16 或更高"
else
  XCODE_VER="$(xcodebuild -version 2>/dev/null | head -n1 | awk '{print $2}')"
  echo "    当前: Xcode $XCODE_VER"
  XCODE_MAJOR="${XCODE_VER%%.*}"
  if [ -n "$XCODE_MAJOR" ] && [ "$XCODE_MAJOR" -lt 16 ] 2>/dev/null; then
    warn "Xcode $XCODE_VER < 16，Swift 6 strict concurrency 可能编不过；建议升级"
  fi
fi

# ----- 4. Homebrew -----
step "检查 / 安装 Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew 未安装；启动官方安装脚本"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Apple Silicon 用户需手动加 PATH（一般在 /opt/homebrew/bin）
  if [ -x "/opt/homebrew/bin/brew" ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
else
  echo "    已安装：$(brew --version | head -n1)"
fi

# ----- 5. xcodegen -----
step "安装 / 升级 xcodegen"
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
else
  echo "    已安装：$(xcodegen --version 2>&1 | head -n1)"
  echo "    可选升级：brew upgrade xcodegen"
fi

# ----- 6. git clone 提示 -----
step "检查当前是否在 ${PROJECT_NAME} 仓库中"
if [ ! -f "$PROJECT_YML" ]; then
  warn "当前目录未发现 ${PROJECT_YML}"
  cat <<EOF

如果你尚未克隆仓库，请执行：

    git clone ${REPO_URL}
    cd ${PROJECT_NAME}
    ./scripts/setup_dev.sh

如果你已经克隆但 cwd 不在仓库根目录，请先 cd 进去再跑本脚本。

EOF
  exit 0
else
  echo "    OK：找到 ${PROJECT_YML}"
fi

# ----- 7. xcodegen generate -----
step "生成 Xcode 工程（xcodegen generate）"
xcodegen generate

if [ ! -d "$XCODEPROJ" ]; then
  fail "xcodegen 未产出 ${XCODEPROJ}，请检查 ${PROJECT_YML} 是否合法"
fi

# ----- 8. 打开工程 -----
step "打开 ${XCODEPROJ}"
open "$XCODEPROJ"

# ----- 收尾提示 -----
cat <<EOF

${GREEN}${BOLD}环境就绪 ✅${NC}

下一步建议：

  1. Xcode 顶部菜单 → Settings → Accounts → 用 Apple ID 登录（Free Apple ID 即可）
  2. 选中 ${PROJECT_NAME} target → Signing & Capabilities → Team 选 Personal Team
  3. 点 Run 跑起来；首次运行会触发 TCC（Full Disk Access）授权引导

跑测试（任选其一）：

  • Swift Package：cd Packages/ScanKit && swift test
  • 全部 6 包：    见 README.md "跑测试" 章节
  • Xcode scheme： xcodebuild -scheme ${PROJECT_NAME} -configuration Debug test

打包 alpha DMG：

  ./scripts/make_dmg.sh build/Build/Products/Debug/${PROJECT_NAME}.app

EOF
