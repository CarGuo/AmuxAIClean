#!/usr/bin/env bash
# build_release.sh —— AmuxAIClean Release 打包
#
# 用法:
#   ./Scripts/build_release.sh                 # 默认：Developer ID 签名 + DMG，不公证
#   ./Scripts/build_release.sh --notarize      # Developer ID 签 App/DMG，只公证最终 DMG
#   ./Scripts/build_release.sh --app-only      # 只构建 .app，不生成 DMG
#   VERSION=1.0.0 ./Scripts/build_release.sh   # 指定版本号写进 Info.plist 与产物文件名
#
# 设计原则（Step 5.6 番外回归 Xcode 原生路径）：
#   - 不再做签名身份决议；签名完全由 .xcodeproj 里的 Release Manual + Developer ID Application 决定
#   - 不再调用 xcodegen；.xcodeproj 已入仓
#   - 当前项目配置使用 Developer ID Application: SentenceEnd Inc (W6H34N9728)；
#     公网分发通过 --notarize 完成 DMG notary / staple / Gatekeeper 闭环。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

absolute_path_from_root() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$ROOT" "$1" ;;
  esac
}

PROJECT_NAME="GSYCleanMac"
APP_NAME="AmuxAIClean"
SCHEME="GSYCleanMac"
PROJECT="${ROOT}/${PROJECT_NAME}.xcodeproj"
CONFIG="${CONFIG:-Release}"
VERSION="${VERSION:-}"
BUILD_DIR="$(absolute_path_from_root "${BUILD_DIR:-build/release}")"
DIST_DIR="$(absolute_path_from_root "${DIST_DIR:-dist}")"
NOTARY_PROFILE="${AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE:-${PASTE_MIND_NOTARY_KEYCHAIN_PROFILE:-${NOTARY_KEYCHAIN_PROFILE:-amux-notary}}}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-45m}"
MAKE_DMG=1
APP_ONLY=0
NOTARIZE=0
DMG_PATH="${DMG_PATH:-}"
DMG_SHA_PATH=""
PROVENANCE_PATH=""

if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi
step() { printf "${BOLD}${GREEN}==>${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}!! %s${NC}\n" "$*" >&2; }
fail() { printf "${RED}xx %s${NC}\n" "$*" >&2; exit 1; }

compute_source_state() {
  local status_output
  status_output="$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" || return 1
  if [ -n "$status_output" ]; then
    printf 'dirty\n'
  else
    printf 'clean\n'
  fi
}

# Produce a checkout-location-independent digest of every source byte outside
# HEAD. Git diff paths are relative already; for untracked files, record only
# the relative path and content digest (never shasum's absolute filename).
compute_source_fingerprint() {
  local work tracked_diff untracked_list manifest
  local untracked source_path content_hash link_target
  work="$(mktemp -d -t amuxaiclean_source_fingerprint)" || return 1
  tracked_diff="$work/tracked.diff"
  untracked_list="$work/untracked.list"
  manifest="$work/manifest"

  git -C "$ROOT" diff --binary HEAD -- . > "$tracked_diff" || {
    rm -rf "$work"
    return 1
  }
  git -C "$ROOT" ls-files -z --others --exclude-standard \
    | LC_ALL=C sort -z > "$untracked_list" || {
      rm -rf "$work"
      return 1
    }
  cp "$tracked_diff" "$manifest" || {
    rm -rf "$work"
    return 1
  }

  while IFS= read -r -d '' untracked; do
    [ -n "$untracked" ] || continue
    source_path="$ROOT/$untracked"
    if [ -L "$source_path" ]; then
      link_target="$(readlink "$source_path")" || {
        rm -rf "$work"
        return 1
      }
      content_hash="$(printf '%s' "$link_target" | shasum -a 256 | awk '{print $1}')" || {
        rm -rf "$work"
        return 1
      }
      printf 'UNTRACKED_SYMLINK\0%s\0%s\0' "$untracked" "$content_hash" >> "$manifest"
    elif [ -f "$source_path" ]; then
      content_hash="$(shasum -a 256 "$source_path" | awk '{print $1}')" || {
        rm -rf "$work"
        return 1
      }
      printf 'UNTRACKED_FILE\0%s\0%s\0' "$untracked" "$content_hash" >> "$manifest"
    else
      printf 'source changed while fingerprinting: %s\n' "$untracked" >&2
      rm -rf "$work"
      return 1
    fi
  done < "$untracked_list"

  content_hash="$(shasum -a 256 "$manifest" | awk '{print $1}')" || {
    rm -rf "$work"
    return 1
  }
  rm -rf "$work"
  printf '%s\n' "$content_hash"
}

usage() {
  cat <<EOF
用法: $0 [--notarize|--no-notarize] [--app-only]

模式:
  --no-notarize   默认。构建 Developer ID 签名 .app，并生成未公证 DMG
  --notarize      Developer ID 签 App 与最终 DMG，只提交 DMG 到 Apple Notary，staple 后再校验
  --app-only      只构建 .app，不生成 DMG；可与 --no-notarize 一起用于快速验证

常用环境变量:
  VERSION=1.6.0
  BUILD_NUMBER=1234
  BUILD_DIR=build/release
  DIST_DIR=dist
  DMG_PATH=dist/AmuxAIClean-1.6.0.dmg
  AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary
  NOTARY_TIMEOUT=45m

示例:
  VERSION=1.6.0 $0 --no-notarize
  VERSION=1.6.0 AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary $0 --notarize
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --notarize)
      NOTARIZE=1
      ;;
    --no-notarize)
      NOTARIZE=0
      ;;
    --app-only)
      APP_ONLY=1
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

if [ "$NOTARIZE" -eq 1 ] && [ "$APP_ONLY" -eq 1 ]; then
  fail "--notarize 是 DMG-only 公证流程，不能与 --app-only 同时使用"
fi

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

  case "$submit_out" in
    *"status: Accepted"*) ;;
    *)
    if [ -n "$submission_id" ]; then
      warn "Apple Notary 未返回 Accepted，尝试读取 log：$submission_id"
      xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" || true
    fi
    fail "${label} 公证未通过"
    ;;
  esac
}

staple_file() {
  local file_path="$1"
  local label="$2"
  step "staple ${label}"
  xcrun stapler staple "$file_path"
  xcrun stapler validate "$file_path"
}

assess_dmg() {
  local dmg_path="$1"
  step "Gatekeeper 校验 DMG"
  spctl -a -vv -t open --context context:primary-signature "$dmg_path"
}

verify_release_dmg() {
  local dmg_path="$1"
  local label="$2"
  step "验证 ${label} 的最终字节与内部 App"
  codesign --verify --strict --verbose=4 "$dmg_path"
  "$ROOT/Scripts/verify_dmg.sh" "$dmg_path" "${APP_NAME}.app" "$PROVENANCE_PATH"
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
# v1.5.7：CFBundleVersion 用 commit count 单调递增。
# Sparkle / Apple App Store / Gatekeeper TCC 缓存均依赖 CFBundleVersion 判定是否"新版本"，
# 若多次 release 共用同一个 build 号会导致 update 静默失败、TCC 权限被错误复用。
if [ -z "${BUILD_NUMBER:-}" ]; then
    BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)" || fail "无法从 git 生成 CFBundleVersion"
fi
GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD)" || fail "无法读取 git HEAD"
GIT_FULL_SHA="$(git -C "$ROOT" rev-parse HEAD)" || fail "无法读取完整 git HEAD"
SOURCE_STATE="$(compute_source_state)" || fail "无法读取源码 clean/dirty 状态"
# HEAD 之外的全部 tracked diff + untracked 文件内容摘要。公证 dirty tree 时不能把产物
# 伪装成纯 HEAD；这个 fingerprint 会写入 DMG 内隐藏的 provenance 文件和同名 sidecar。
SOURCE_FINGERPRINT="$(compute_source_fingerprint)" || fail "无法计算源码 fingerprint"
step "Build number: ${BUILD_NUMBER} (git sha: ${GIT_SHA}, source: ${SOURCE_STATE}, fingerprint: ${SOURCE_FINGERPRINT})"
if [ "$SOURCE_STATE" = "dirty" ]; then
    warn "正在构建含未提交改动的可追溯产物；DMG 内与 dist sidecar 会记录 dirty fingerprint"
fi

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

step "确认构建期间源码与 HEAD 未变化"
GIT_FULL_SHA_AFTER="$(git -C "$ROOT" rev-parse HEAD)" || fail "构建后无法读取 git HEAD"
SOURCE_STATE_AFTER="$(compute_source_state)" || fail "构建后无法读取源码状态"
SOURCE_FINGERPRINT_AFTER="$(compute_source_fingerprint)" || fail "构建后无法计算源码 fingerprint"
if [ "$GIT_FULL_SHA_AFTER" != "$GIT_FULL_SHA" ] \
  || [ "$SOURCE_STATE_AFTER" != "$SOURCE_STATE" ] \
  || [ "$SOURCE_FINGERPRINT_AFTER" != "$SOURCE_FINGERPRINT" ]; then
    fail "构建期间源码或 HEAD 发生变化；拒绝为来源不确定的产物生成 DMG"
fi

APP_PATH="$BUILD_DIR/Build/Products/${CONFIG}/${APP_NAME}.app"
[ -d "$APP_PATH" ] || fail "构建产物未生成：$APP_PATH"
DIST_APP_PATH="$DIST_DIR/${APP_NAME}.app"

step "复制产物到 ${DIST_APP_PATH}"
ditto "$APP_PATH" "$DIST_APP_PATH"

step "校验 codesign"
codesign --verify --deep --strict --verbose=4 "$DIST_APP_PATH"
codesign -dv --verbose=2 "$DIST_APP_PATH" 2>&1 | head -8 || true

# v1.5.7：核对 Hardened Runtime 是否开启
# Release 走 .xcodeproj 里的 ENABLE_HARDENED_RUNTIME = YES；如果被改回 NO，直接终止发布。
# ad-hoc 签名: flags=0x10002(adhoc,runtime); Developer ID: flags=0x10000(runtime); Personal Team 又不同
# 用正则匹配括号内出现 runtime, 兼容三种签名身份
# 注意: 先缓存到变量再 grep, 不能 codesign | grep -q —— -q 提前 quit 在 pipefail 下让上游收 SIGPIPE 误报失败
CS_OUT=$(codesign -d --verbose=4 "$DIST_APP_PATH" 2>&1 || true)
if echo "$CS_OUT" | grep -Eq "flags=0x[0-9a-fA-F]+\([^)]*runtime"; then
    echo "  ✓ Hardened Runtime: enabled"
else
    fail "Hardened Runtime 未启用（codesign flags 未含 runtime）"
fi
case "$CS_OUT" in
    *"Timestamp="*) echo "  ✓ Secure timestamp: present" ;;
    *) fail "App Developer ID 签名缺少 secure timestamp" ;;
esac

APP_SIGNING_IDENTITY="$(printf '%s\n' "$CS_OUT" | awk '
  /^Authority=Developer ID Application:/ && !found {
    sub(/^Authority=/, "")
    print
    found = 1
  }
')"
if [ -z "$APP_SIGNING_IDENTITY" ]; then
    fail "App 不是 Developer ID Application 签名，拒绝生成发布 DMG"
fi
echo "  ✓ Developer ID identity: ${APP_SIGNING_IDENTITY}"

step "校验 Info.plist 版本一致性"
PLIST="$DIST_APP_PATH/Contents/Info.plist"
ACTUAL_SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST" 2>/dev/null || echo "?")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST" 2>/dev/null || echo "?")
[ "$ACTUAL_SHORT" != "?" ] || fail "无法读取 CFBundleShortVersionString"
[ "$ACTUAL_BUILD" != "?" ] || fail "无法读取 CFBundleVersion"
if [ -n "$VERSION" ] && [ "$ACTUAL_SHORT" != "$VERSION" ]; then
    fail "MARKETING_VERSION 写入失败（期望 ${VERSION}，实际 ${ACTUAL_SHORT}）"
fi
RELEASE_VERSION="${VERSION:-${ACTUAL_SHORT}}"
echo "  CFBundleShortVersionString = ${ACTUAL_SHORT}"
echo "  CFBundleVersion            = ${ACTUAL_BUILD}"
if [ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]; then
    fail "CFBundleVersion 写入失败（期望 ${BUILD_NUMBER}，实际 ${ACTUAL_BUILD}）"
fi

PROVENANCE_PATH="$DIST_DIR/${APP_NAME}-${RELEASE_VERSION}.provenance.json"
BUILD_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
cat > "$PROVENANCE_PATH" <<EOF
{
  "schemaVersion": 1,
  "product": "${APP_NAME}",
  "version": "${RELEASE_VERSION}",
  "buildNumber": "${BUILD_NUMBER}",
  "gitHead": "${GIT_FULL_SHA}",
  "sourceState": "${SOURCE_STATE}",
  "sourceFingerprintSHA256": "${SOURCE_FINGERPRINT}",
  "builtAtUTC": "${BUILD_UTC}"
}
EOF
jq empty "$PROVENANCE_PATH" 2>/dev/null || fail "构建 provenance JSON 无效：$PROVENANCE_PATH"

DMG_PATH="$(absolute_path_from_root "${DMG_PATH:-${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}.dmg}")"

if [ "$MAKE_DMG" -eq 1 ]; then
    DMG_SHA_PATH="${DMG_PATH}.sha256"
    mkdir -p "$(dirname "$DMG_PATH")"
    # A failed signing/notary run must not leave a checksum from an older DMG next
    # to the newly replaced, incomplete candidate.
    rm -f "$DMG_SHA_PATH"
    step "生成 DMG：${DMG_PATH}"
    DMG_PROVENANCE_FILE="$PROVENANCE_PATH" ./Scripts/make_dmg.sh "$DIST_APP_PATH" "$DMG_PATH"

    step "使用 App 的 Developer ID Application 身份签名最终 DMG"
    codesign --force --timestamp --sign "$APP_SIGNING_IDENTITY" "$DMG_PATH"
    codesign --verify --strict --verbose=4 "$DMG_PATH"
    DMG_CS_OUT=$(codesign -d --verbose=4 "$DMG_PATH" 2>&1 || true)
    case "$DMG_CS_OUT" in
        *"Authority=${APP_SIGNING_IDENTITY}"*) ;;
        *) fail "DMG 签名身份与 App 不一致" ;;
    esac
    case "$DMG_CS_OUT" in
        *"Timestamp="*) ;;
        *) fail "DMG Developer ID 签名缺少 secure timestamp" ;;
    esac
    verify_release_dmg "$DMG_PATH" "已签名 DMG"

    if [ "$NOTARIZE" -eq 1 ]; then
        # DMG-only：Apple 会检查容器内已签名 App；不要额外 zip/submit/staple App。
        notarize_file "$DMG_PATH" "DMG"
        staple_file "$DMG_PATH" "DMG"
        assess_dmg "$DMG_PATH"
        verify_release_dmg "$DMG_PATH" "已 staple DMG"
    else
        warn "已生成未公证 DMG；只适合本地/内部快速验证，不等价于 Gatekeeper 公开分发闭环"
    fi

    # Signing and stapling both mutate the DMG. Hash only the final distributable bytes.
    step "生成最终 DMG SHA256：${DMG_SHA_PATH}"
    (
        cd "$(dirname "$DMG_PATH")"
        shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_SHA_PATH")"
    )
fi

cat <<EOF

${GREEN}${BOLD}Release 构建完成${NC}
  配置:       ${CONFIG}
  版本:       ${RELEASE_VERSION}
  Build:      ${BUILD_NUMBER} (git ${GIT_SHA})
  Source:     ${SOURCE_STATE} (${SOURCE_FINGERPRINT})
  Provenance: ${PROVENANCE_PATH}
  App:        ${DIST_APP_PATH}
  DMG:        $([ "$MAKE_DMG" -eq 1 ] && printf '%s' "$DMG_PATH" || printf '未生成 (--app-only)')
  SHA256:     $([ "$MAKE_DMG" -eq 1 ] && printf '%s' "$DMG_SHA_PATH" || printf '未生成')
  签名:       App 与 DMG 使用同一 Developer ID Application
  公证:       $([ "$NOTARIZE" -eq 1 ] && printf '仅提交最终 DMG，并已 staple/验收' || printf '未公证')

EOF
