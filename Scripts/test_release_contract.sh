#!/usr/bin/env bash
# Static contract test for the public DMG release chain.
# It performs no build, signing, notarization, stapling, or network operation.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${ROOT}/Scripts/build_release.sh"
DMG_TARGET="${ROOT}/Scripts/make_dmg.sh"
VERIFY_TARGET="${ROOT}/Scripts/verify_dmg.sh"

fail() {
  printf 'release contract failed: %s\n' "$*" >&2
  exit 1
}

require_fixed() {
  local needle="$1"
  grep -Fq -- "$needle" "$TARGET" || fail "missing contract: ${needle}"
}

require_dmg_fixed() {
  local needle="$1"
  grep -Fq -- "$needle" "$DMG_TARGET" || fail "missing DMG contract: ${needle}"
}

require_verify_fixed() {
  local needle="$1"
  grep -Fq -- "$needle" "$VERIFY_TARGET" || fail "missing DMG verification contract: ${needle}"
}

line_of() {
  local needle="$1"
  awk -v needle="$needle" 'index($0, needle) { print NR; exit }' "$TARGET"
}

last_line_of() {
  local needle="$1"
  awk -v needle="$needle" 'index($0, needle) { line = NR } END { if (line) print line }' "$TARGET"
}

bash -n "$TARGET"
bash -n "$DMG_TARGET"
bash -n "$VERIFY_TARGET"

# Artifact paths must be rooted once. This prevents DIST_DIR=dist from becoming
# <repo>/dist/dist/... when DMG_PATH is derived later.
require_fixed 'BUILD_DIR="$(absolute_path_from_root "${BUILD_DIR:-build/release}")"'
require_fixed 'DIST_DIR="$(absolute_path_from_root "${DIST_DIR:-dist}")"'
require_fixed 'DMG_PATH="$(absolute_path_from_root "${DMG_PATH:-${DIST_DIR}/${APP_NAME}-${RELEASE_VERSION}.dmg}")"'
require_fixed '"sourceState": "${SOURCE_STATE}"'
require_fixed '"sourceFingerprintSHA256": "${SOURCE_FINGERPRINT}"'
require_fixed 'SOURCE_FINGERPRINT_AFTER="$(compute_source_fingerprint)"'
require_fixed '[ "$SOURCE_FINGERPRINT_AFTER" != "$SOURCE_FINGERPRINT" ]'
require_fixed 'git -C "$ROOT" ls-files -z --others --exclude-standard'
require_fixed "while IFS= read -r -d '' untracked; do"
require_fixed 'if [ -n "$VERSION" ] && [ "$ACTUAL_SHORT" != "$VERSION" ]; then'
require_fixed 'fail "CFBundleVersion 写入失败（期望 ${BUILD_NUMBER}，实际 ${ACTUAL_BUILD}）"'
require_fixed 'DMG_PROVENANCE_FILE="$PROVENANCE_PATH" ./Scripts/make_dmg.sh "$DIST_APP_PATH" "$DMG_PATH"'
require_dmg_fixed 'cp "$DMG_PROVENANCE_FILE" "$STAGE_DIR/.build-provenance.json"'

# Packaging must use a private, verified mount identity and then read-only mount
# the produced image to prove the App/provenance really landed in that DMG.
require_dmg_fixed 'make_dmg_with_hdiutil_strict() ('
require_dmg_fixed '-mountpoint "$expected_mount" -plist'
require_dmg_fixed 'set targetDisk to disk of targetVolume'
require_dmg_fixed '"$ROOT_DIR/Scripts/verify_dmg.sh" "$DMG_PATH" "$APP_BASENAME" "$DMG_PROVENANCE_FILE"'
require_verify_fixed 'hdiutil verify "$DMG_PATH"'
require_verify_fixed '[ -f "$PLIST" ]'
require_verify_fixed 'codesign --verify --deep --strict --verbose=4 "$APP_PATH"'
require_verify_fixed 'cmp -s "$PROVENANCE_FILE" "$MOUNT_POINT/.build-provenance.json"'
if grep -Fq -- 'MOUNT_POINT="/Volumes/$VOLUME_NAME"' "$DMG_TARGET"; then
  fail "DMG packaging hard-codes a shared /Volumes mount point"
fi
if grep -Eq 'if[[:space:]]+![[:space:]]+make_dmg_with_hdiutil' "$DMG_TARGET"; then
  fail "DMG primary function is called in a Bash errexit-suppressing condition"
fi
if grep -Fq -- 'shasum -a 256 "$ROOT/$untracked"' "$TARGET"; then
  fail "source fingerprint leaks checkout absolute paths"
fi

# The notarized unit is exactly the final DMG. App zip submission/stapling would
# reintroduce the obsolete double-notarization workflow.
[ "$(grep -Ec '^[[:space:]]+notarize_file "\$DMG_PATH" "DMG"[[:space:]]*$' "$TARGET")" -eq 1 ] \
  || fail "expected exactly one DMG notary submission"
[ "$(grep -Ec '^[[:space:]]+staple_file "\$DMG_PATH" "DMG"[[:space:]]*$' "$TARGET")" -eq 1 ] \
  || fail "expected exactly one DMG staple"
[ "$(grep -Ec '^[[:space:]]+assess_dmg "\$DMG_PATH"[[:space:]]*$' "$TARGET")" -eq 1 ] \
  || fail "expected exactly one DMG Gatekeeper assessment"
[ "$(grep -Ec '^[[:space:]]+verify_release_dmg "\$DMG_PATH" ' "$TARGET")" -eq 2 ] \
  || fail "expected signed and final-stapled DMG verification"
if grep -Eq 'APP_NOTARY|app-notary|notarize_file .*APP|staple_file .*DIST_APP|assess_app|ditto -c -k' "$TARGET"; then
  fail "App zip submission or App stapling reappeared"
fi

# The final-byte order is part of the release contract:
# package -> sign -> submit -> staple -> assess -> hash.
checksum_cleanup_line="$(line_of 'rm -f "$DMG_SHA_PATH"')"
make_line="$(line_of './Scripts/make_dmg.sh "$DIST_APP_PATH" "$DMG_PATH"')"
sign_line="$(line_of 'codesign --force --timestamp --sign "$APP_SIGNING_IDENTITY" "$DMG_PATH"')"
notary_line="$(line_of 'notarize_file "$DMG_PATH" "DMG"')"
staple_line="$(line_of 'staple_file "$DMG_PATH" "DMG"')"
assess_line="$(line_of 'assess_dmg "$DMG_PATH"')"
final_verify_line="$(last_line_of 'verify_release_dmg "$DMG_PATH"')"
hash_line="$(line_of 'shasum -a 256 "$(basename "$DMG_PATH")"')"

for value in "$checksum_cleanup_line" "$make_line" "$sign_line" "$notary_line" "$staple_line" "$assess_line" "$final_verify_line" "$hash_line"; do
  [ -n "$value" ] || fail "could not determine release step order"
done

if ! [ "$checksum_cleanup_line" -lt "$make_line" ] \
  || ! [ "$make_line" -lt "$sign_line" ] \
  || ! [ "$sign_line" -lt "$notary_line" ] \
  || ! [ "$notary_line" -lt "$staple_line" ] \
  || ! [ "$staple_line" -lt "$assess_line" ] \
  || ! [ "$assess_line" -lt "$final_verify_line" ] \
  || ! [ "$final_verify_line" -lt "$hash_line" ]; then
  fail "DMG release steps are out of order"
fi

# This invalid option combination must fail before xcodebuild, so it is safe to
# exercise as an injected behavioral check on every development machine.
guard_output="$(mktemp -t amuxaiclean-release-contract)"
trap 'rm -f "$guard_output"' EXIT
assert_app_only_notarize_rejected() {
  if "$TARGET" "$@" >"$guard_output" 2>&1; then
    fail "$* unexpectedly succeeded"
  fi
  grep -Fq -- 'DMG-only' "$guard_output" \
    || fail "$* did not explain the DMG-only contract"
}
assert_app_only_notarize_rejected --notarize --app-only
assert_app_only_notarize_rejected --app-only --notarize

printf 'release contract passed: DMG-only notary order, final-byte remount proof, NUL-safe provenance, and final SHA256 verified\n'
