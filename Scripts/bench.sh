#!/usr/bin/env bash
# ScanKit 基准测试脚本：与系统 du 对比，验证扫描正确性。
# 用法：./Scripts/bench.sh <path>
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "用法: $0 <path>"
  echo "例:  $0 ~/Downloads"
  exit 64
fi

TARGET="$1"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> 编译 ScanKit Bench (release)"
cd "$ROOT_DIR/Packages/ScanKit"
swift build -c release --product scankit-bench

BENCH="$ROOT_DIR/Packages/ScanKit/.build/release/scankit-bench"

echo
echo "==> 我们的扫描器 (默认: 隐藏文件 + 物理占用 + inode 去重)"
time "$BENCH" "$TARGET"

echo
echo "==> 系统 du -sh (含隐藏，逻辑大小)"
time du -sh "$TARGET" 2>/dev/null || true

echo
echo "==> 系统 du -sh -A (apparent size)"
time du -sh -A "$TARGET" 2>/dev/null || true

echo
echo "对比说明："
echo "  - on disk  ≈ du -sh         （都是物理块占用）"
echo "  - logical  ≈ du -sh -A      （都是逻辑大小）"
echo "  - 若两者差距大，说明该目录有 iCloud 占位 / 稀疏文件 / 压缩文件"
echo "  - hardlink dedup saved 体现硬链接节省（Time Machine 类目录）"
