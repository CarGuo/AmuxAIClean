#!/usr/bin/env bash
# setup_dev.sh —— GSYCleanMac 新机器开发环境初始化
#
# 用法：
#   ./Scripts/setup_dev.sh
#
# Step 5.6 番外回归 Xcode 原生路径后，本脚本仅做环境检查 + 引导：
#   1. 检查 macOS 版本（PITFALLS §1.2 锁 15+）
#   2. 检查 Xcode CLT / Xcode 是否已装
#   3. 安装 / 升级 Homebrew（可选；用于 brew install xcbeautify 等）
#   4. 检查 .xcodeproj 是否已入仓
#   5. 引导用户在 Xcode UI 完成 Apple ID 登录 + Personal Team 选择
#
# 设计原则：每一步幂等，可重复执行不破坏环境

set -euo pipefail

PROJECT_NAME="GSYCleanMac"
XCODEPROJ="GSYCleanMac.xcodeproj"
MIN_MACOS_MAJOR=15

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

# ----- 4. Homebrew（可选） -----
step "检查 Homebrew（可选，用于装 xcbeautify 美化 build 输出）"
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew 未安装；如需 xcbeautify 可执行：/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
else
  echo "    已安装：$(brew --version | head -n1)"
fi

# ----- 5. .xcodeproj 入仓检查 -----
step "检查 ${XCODEPROJ} 是否在仓库里"
if [ ! -d "$XCODEPROJ" ]; then
  fail "未找到 ${XCODEPROJ} —— Step 5.6 番外后该文件应已入仓，请检查 git 状态"
else
  echo "    OK：${XCODEPROJ} 已就绪"
fi

# ----- 收尾提示 -----
cat <<EOF

${GREEN}${BOLD}环境就绪 OK${NC}

下一步（fork 用户必看）：

  1. 双击打开 ${XCODEPROJ}
  2. Xcode 顶部菜单 → Settings → Accounts → 用 Apple ID 登录（免费 Personal Team 即可）
  3. 选中 ${PROJECT_NAME} target → Signing & Capabilities
       - 勾 "Automatically manage signing"
       - Team 下拉选 你的 Personal Team
       - Bundle Identifier 必要时改成你自己的（比如 com.<你的id>.cleanmac.GSYCleanMac）
  4. ⌘R 跑起来；首次运行会触发 TCC（Full Disk Access）授权引导
       —— 此后只要 bundle id + signing requirement 稳定，TCC 授权应继续匹配

跑测试（任选其一）：
  • 单包：       cd Packages/ScanKit && swift test
  • 全部 6 包：   见 README.md "跑测试" 章节
  • Xcode：      ⌘U

打包（自用 / 本机）：
  ./Scripts/build_release.sh

EOF
