#!/usr/bin/env bash
# setup_codesign.sh —— GSYCleanMac 本地开发用自签 codesign 证书一次性配置
#
# 用法：
#   ./Scripts/setup_codesign.sh                       # 幂等：有就跳过，没有就生成并导入登录 keychain
#   eval "$(./Scripts/setup_codesign.sh --export)"    # 输出可被 shell eval 的 export 语句
#
# 行为：
#   1. 检查登录 keychain 是否已存在 CN="GSYCleanMac Local Dev" 的 codesign 证书
#   2. 若不存在，用 openssl + 临时 cert.conf 生成自签 X.509（用途 codesign）并导入登录 keychain
#   3. 把证书 SHA-1 fingerprint echo 出来，build 脚本可以直接读
#
# 设计原则：
#   - 幂等：重复执行不会重复生成，也不会污染 keychain
#   - 零 Apple Developer Program 依赖：完全本地化的"稳定身份"
#   - 解决 TCC 反复授权：只要 codesign 身份的 SHA-1 不变，
#     macOS 就把"全磁盘访问"等授权挂在这个稳定身份上，避免 ad-hoc 每次重签都重新授权

set -euo pipefail

CERT_CN="GSYCleanMac Local Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TMP_DIR="$(mktemp -d -t gsy-codesign-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ----- 颜色辅助 -----
if [ -t 1 ]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; NC=''
fi
step() { printf "${BOLD}${GREEN}==>${NC} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}!! %s${NC}\n" "$*" >&2; }
fail() { printf "${RED}xx %s${NC}\n" "$*" >&2; exit 1; }
info() { printf "    %s\n" "$*" >&2; }

EXPORT_MODE=0
if [ "${1:-}" = "--export" ]; then
  EXPORT_MODE=1
fi

# ----- 1. 依赖检查 -----
command -v security >/dev/null 2>&1 || fail "未找到 security 命令（macOS 自带，理论上不该缺）"
command -v openssl  >/dev/null 2>&1 || fail "未找到 openssl 命令，请先安装 Xcode CLT 或 brew install openssl"

# ----- 2. 查询是否已有同名证书 -----
step "检查登录 keychain 是否已有 codesign 证书：CN=${CERT_CN}"

find_sha1() {
  # 列出所有 codesign 用途证书；筛 CN；提取 SHA-1
  # security find-certificate -c "$CERT_CN" -a -Z 输出格式：
  #   SHA-1 hash: XXXXXXXX...
  #   ... 一堆字段
  security find-certificate -c "$CERT_CN" -a -Z "$KEYCHAIN" 2>/dev/null \
    | awk '/^SHA-1 hash:/ {print $3; exit}'
}

EXISTING_SHA1="$(find_sha1 || true)"

if [ -n "${EXISTING_SHA1:-}" ]; then
  info "已存在证书，SHA-1 = ${EXISTING_SHA1}"
  # 顺便检查它确实带 codesign 用途
  if ! security find-identity -p codesigning -v "$KEYCHAIN" | grep -q "$CERT_CN"; then
    warn "证书存在，但 find-identity -p codesigning 没列出来；可能私钥丢失或用途不匹配"
    warn "如需重置：security delete-certificate -c \"${CERT_CN}\" \"${KEYCHAIN}\" 然后重新跑本脚本"
  fi
  FINAL_SHA1="$EXISTING_SHA1"
else
  step "未找到现有证书，开始生成自签 X.509（用途：codesign）"

  CONF="${TMP_DIR}/cert.conf"
  KEY="${TMP_DIR}/key.pem"
  CRT="${TMP_DIR}/cert.pem"
  P12="${TMP_DIR}/bundle.p12"
  P12_PASS="gsycleanmac-local-dev"

  cat >"$CONF" <<EOF
[ req ]
distinguished_name = req_dn
prompt             = no
x509_extensions    = v3_codesign

[ req_dn ]
CN = ${CERT_CN}
O  = GSYCleanMac
OU = Local Development

[ v3_codesign ]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
EOF

  info "生成 RSA 2048 私钥"
  openssl genrsa -out "$KEY" 2048 >/dev/null 2>&1

  info "生成自签 X.509 证书（10 年有效期）"
  openssl req -new -x509 \
    -key "$KEY" \
    -out "$CRT" \
    -days 3650 \
    -config "$CONF" \
    -extensions v3_codesign >/dev/null 2>&1

  info "打包成 PKCS#12 以便 security import"
  openssl pkcs12 -export \
    -inkey "$KEY" \
    -in "$CRT" \
    -name "${CERT_CN}" \
    -out "$P12" \
    -passout "pass:${P12_PASS}" \
    -legacy >/dev/null 2>&1 \
    || openssl pkcs12 -export \
         -inkey "$KEY" \
         -in "$CRT" \
         -name "${CERT_CN}" \
         -out "$P12" \
         -passout "pass:${P12_PASS}" >/dev/null 2>&1

  info "导入登录 keychain（允许 codesign 直接使用，不再每次弹密码）"
  security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productsign \
    >/dev/null 2>&1

  # 让 codesign 后台调用免输 keychain 密码
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
    warn "set-key-partition-list 失败（首次签名时可能弹一次密码授权，是 macOS 安全机制，正常）"

  FINAL_SHA1="$(find_sha1 || true)"
  [ -n "$FINAL_SHA1" ] || fail "导入完成但 find-certificate 仍找不到，请手动检查 keychain"

  info "证书已导入，SHA-1 = ${FINAL_SHA1}"
fi

# ----- 3. 输出 SHA-1，供 build 脚本读取 -----
if [ "$EXPORT_MODE" -eq 1 ]; then
  echo "export GSYCLEAN_CODESIGN_IDENTITY=${FINAL_SHA1}"
else
  step "完成。证书 SHA-1 fingerprint："
  printf "%s\n" "$FINAL_SHA1"
  cat >&2 <<EOF

接下来在你的 shell 里：

    export GSYCLEAN_CODESIGN_IDENTITY=${FINAL_SHA1}
    ./Scripts/build_release.sh

或者一行搞定：

    eval "\$(./Scripts/setup_codesign.sh --export)"
    xcodebuild -scheme GSYCleanMac -configuration Debug \\
      CODE_SIGN_IDENTITY="\$GSYCLEAN_CODESIGN_IDENTITY" \\
      CODE_SIGN_STYLE=Manual build

EOF
fi
