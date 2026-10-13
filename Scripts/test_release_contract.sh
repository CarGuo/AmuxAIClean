#!/usr/bin/env bash
# Static contract test for the public DMG release chain.
# It performs no build, signing, notarization, stapling, or network operation.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${ROOT}/Scripts/build_release.sh"
DMG_TARGET="${ROOT}/Scripts/make_dmg.sh"
VERIFY_TARGET="${ROOT}/Scripts/verify_dmg.sh"
PROJECT="${ROOT}/AmuxAIClean.xcodeproj"
INFO_PLIST="${ROOT}/App/Info.plist"
INFO_STRINGS_EN="${ROOT}/App/en.lproj/InfoPlist.strings"
INFO_STRINGS_ZH="${ROOT}/App/zh-Hans.lproj/InfoPlist.strings"
PRIVACY_MANIFEST="${ROOT}/App/PrivacyInfo.xcprivacy"
PRIVACY_DOCUMENT="${ROOT}/PRIVACY.md"
CONTRIBUTING_DOCUMENT="${ROOT}/CONTRIBUTING.md"
LOG_SOURCE="${ROOT}/Packages/LogKit/Sources/LogKit/AmuxLog.swift"
LOG_FILE_SINK_SOURCE="${ROOT}/Packages/LogKit/Sources/LogKit/LogFileSink.swift"
SENTINEL_AGENT_PLIST="${ROOT}/App/LaunchAgents/com.amux.ai.Clean.sentinel.agent.plist"
SENTINEL_ORIGINAL_BRAND_DAEMON_PLIST="${ROOT}/App/LaunchDaemons/com.guoshuyu.cleanmac.sentinel.plist"
SENTINEL_LEGACY_DAEMON_PLIST="${ROOT}/App/LaunchDaemons/com.amux.ai.Clean.sentinel.plist"
SENTINEL_MANAGER="${ROOT}/Packages/AppUI/Sources/AppUI/SentinelManager.swift"
SENTINEL_MAIN="${ROOT}/Tools/Sentinel/Sources/Sentinel/main.swift"
DEPLOYMENT_TARGET="13.5"
PACKAGE_DUMP=""
guard_output=""

cleanup() {
  [ -z "$PACKAGE_DUMP" ] || rm -f "$PACKAGE_DUMP"
  [ -z "$guard_output" ] || rm -f "$guard_output"
}
trap cleanup EXIT

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

# v2026.07.16: read the effective Xcode settings by configuration instead of
# counting source-text lines in project.pbxproj. This does not build or start the app.
for configuration in Debug Release; do
  effective_target="$(
    xcodebuild -project "$PROJECT" -scheme AmuxAIClean \
      -configuration "$configuration" -showBuildSettings 2>/dev/null \
      | awk '$1 == "MACOSX_DEPLOYMENT_TARGET" { print $3; exit }'
  )"
  [ "$effective_target" = "$DEPLOYMENT_TARGET" ] \
    || fail "${configuration} effective deployment target is ${effective_target:-missing}, expected ${DEPLOYMENT_TARGET}"
done

info_minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
[ "$info_minimum" = '$(MACOSX_DEPLOYMENT_TARGET)' ] \
  || fail "Info.plist must inherit LSMinimumSystemVersion from MACOSX_DEPLOYMENT_TARGET"

# v2026.07.18: privacy prompts and the bundled manifest are release contracts, not
# optional Xcode metadata. Validate plist syntax and target membership before building.
for usage_key in \
  NSAppDataUsageDescription \
  NSAppBundlesUsageDescription \
  NSDesktopFolderUsageDescription \
  NSDocumentsFolderUsageDescription \
  NSDownloadsFolderUsageDescription \
  NSRemovableVolumesUsageDescription \
  NSNetworkVolumesUsageDescription; do
  usage_value="$(/usr/libexec/PlistBuddy -c "Print :${usage_key}" "$INFO_PLIST" 2>/dev/null || true)"
  [ -n "$usage_value" ] || fail "Info.plist is missing ${usage_key}"
  for strings_file in "$INFO_STRINGS_EN" "$INFO_STRINGS_ZH"; do
    localized_value="$(/usr/bin/plutil -extract "$usage_key" raw -o - "$strings_file" 2>/dev/null || true)"
    [ -n "$localized_value" ] || fail "$(basename "$(dirname "$strings_file")") is missing ${usage_key}"
  done
done
/usr/bin/plutil -lint "$PRIVACY_MANIFEST" >/dev/null \
  || fail "PrivacyInfo.xcprivacy is not a valid property list"
tracking_value="$(/usr/bin/plutil -extract NSPrivacyTracking raw -o - "$PRIVACY_MANIFEST")"
[ "$tracking_value" = "false" ] || fail "privacy manifest must declare tracking=false"
tracking_domains="$(/usr/bin/plutil -extract NSPrivacyTrackingDomains json -o - "$PRIVACY_MANIFEST")"
[ "$tracking_domains" = "[]" ] || fail "privacy manifest must not declare tracking domains"
# v2026.07.18 AI identity-data correction: validate the semantic set, not array positions.
# A configured Bearer key is an account/project-level identifier at the selected provider. Since
# custom compatible providers are allowed, the release cannot assume every recipient immediately
# discards it under Apple's real-time authentication-token exception.
if ! /usr/bin/python3 - "$PRIVACY_MANIFEST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    manifest = plistlib.load(handle)

entries = manifest.get("NSPrivacyCollectedDataTypes")
if not isinstance(entries, list):
    raise SystemExit("NSPrivacyCollectedDataTypes must be an array")

expected = {
    "NSPrivacyCollectedDataTypeOtherUserContent",
    "NSPrivacyCollectedDataTypeOtherDataTypes",
    "NSPrivacyCollectedDataTypeUserID",
}
actual = [entry.get("NSPrivacyCollectedDataType") for entry in entries]
if len(actual) != len(set(actual)):
    raise SystemExit("privacy collected-data declarations contain a duplicate type")
if set(actual) != expected:
    raise SystemExit(f"privacy collected-data types drifted: {sorted(actual)}")

for entry in entries:
    data_type = entry["NSPrivacyCollectedDataType"]
    if entry.get("NSPrivacyCollectedDataTypeLinked") is not True:
        raise SystemExit(f"{data_type} must remain conservatively linked")
    if entry.get("NSPrivacyCollectedDataTypeTracking") is not False:
        raise SystemExit(f"{data_type} must not track")
    if entry.get("NSPrivacyCollectedDataTypePurposes") != [
        "NSPrivacyCollectedDataTypePurposeAppFunctionality"
    ]:
        raise SystemExit(f"{data_type} must be used only for App Functionality")
PY
then
  fail "privacy manifest no longer matches the documented optional-AI transfer boundary"
fi

# v2026.07.18 platform-scope correction: Apple's current Required Reason API declaration
# requirement covers iOS/iPadOS/tvOS/visionOS/watchOS, not this Developer ID macOS-only target.
# A mobile reason code is not a neutral API inventory: 85F4.1, for example, restricts derived
# disk-space data to display, while shipped macOS statfs calls also classify media/read-only
# volumes locally. Keep NSPrivacyAccessedAPITypes absent until the target or Apple's documented
# platform scope changes and the actual uses can be mapped to approved reasons truthfully.
if /usr/bin/plutil -extract NSPrivacyAccessedAPITypes json -o - \
    "$PRIVACY_MANIFEST" >/dev/null 2>&1; then
  fail "macOS privacy manifest must not over-declare mobile Required Reason API codes"
fi
grep -Fq 'PrivacyInfo.xcprivacy in Resources' "${PROJECT}/project.pbxproj" \
  || fail "PrivacyInfo.xcprivacy is not included in the app target resources"

# The rolling file log is deliberately user-readable, but its duplicate in macOS Unified
# Logging must never publish preformatted paths as public. Privacy docs must also retain the
# user-selected export and system-managed log boundaries.
grep -Fq 'privacy: .private(mask: .hash)' "$LOG_SOURCE" \
  || fail "Unified Logging message privacy drifted from private hash"
if grep -Fq 'privacy: .public' "$LOG_SOURCE"; then
  fail "Unified Logging must not publish preformatted path-bearing messages"
fi
# v2026.07.18: NSLog and raw stderr writes bypass the privacy mask above and have a separate,
# system-managed retention lifecycle. Product UI/App sources must use AmuxLog; the two low-level
# file-sink fallbacks may emit only stable numeric diagnostics, never a raw Error or log line.
if grep -R --include='*.swift' -n 'NSLog(' \
  "${ROOT}/App" "${ROOT}/Packages/AppUI/Sources" >/dev/null; then
  fail "product sources must not bypass AmuxLog with NSLog"
fi
grep -Fq 'writeFallbackDiagnostic("file sink write failed", failure: failure)' "$LOG_FILE_SINK_SOURCE" \
  || fail "LogFileSink stderr fallback no longer uses the redacted diagnostic boundary"
grep -Fq 'public static var fileSinkHealth: LogFileSinkHealth' "$LOG_SOURCE" \
  || fail "AmuxLog no longer exposes typed local file-sink health"
grep -Fq 'public static func prepareLogDirectoryForAccess() async -> Result<URL, LogFileSinkFailure>' "$LOG_SOURCE" \
  || fail "Finder/settings log access no longer uses the typed sink validation boundary"
grep -Fq 'public static func currentLogFiles() async -> Result<[URL], LogFileSinkFailure>' "$LOG_SOURCE" \
  || fail "log inventory must remain typed and off the UI thread"
grep -Fq 'public static func exportLogs(to destination: URL) async -> Result<Int, LogFileSinkFailure>' "$LOG_SOURCE" \
  || fail "log export must remain typed and off the UI thread"
grep -Fq 'public static func clearLogs() async -> Result<Int, LogFileSinkFailure>' "$LOG_SOURCE" \
  || fail "log clear must remain typed and off the UI thread"
if grep -Fq 'FileHandle.standardError.write(data)' "$SENTINEL_MAIN"; then
  fail "Sentinel stderr fallback must not mirror path-bearing log data"
fi
grep -Fq 'macOS Unified Logging' "$PRIVACY_DOCUMENT" \
  || fail "PRIVACY.md does not disclose the system-managed log copy"
grep -Fq 'AmuxAIClean-Logs.txt' "$PRIVACY_DOCUMENT" \
  || fail "PRIVACY.md does not disclose user-selected log exports"
grep -Fq '不允许新增或扩大网络请求' "$CONTRIBUTING_DOCUMENT" \
  || fail "CONTRIBUTING.md does not preserve the closed network boundary"
if grep -Fq '本项目零网络是 hard rule' "$CONTRIBUTING_DOCUMENT"; then
  fail "CONTRIBUTING.md still contradicts the two real outbound workflows"
fi

# v2026.07.18: Sentinel observes the signed-in user's Home/Trash and must therefore be a
# non-privileged login agent. Older builds registered two root LaunchDaemon Labels, so each
# historical authority keeps a stable migration-only descriptor whose file name matches its Label.
# v2026.10.14: branding cannot retire either installed authority; validate both real identities,
# their bundle embedding and never-register contract until their upgrade windows are retired.
# v2026.07.18 P1 executable-entry regression: a stale root LaunchDaemon must fail closed before
# the current user-Agent implementation initializes paths, logs, persistence, or listeners.
grep -Fq 'if geteuid() == 0 {' "$SENTINEL_MAIN" \
  || fail "Sentinel executable does not reject privileged execution"
grep -Fq 'let diagnostic = "AmuxAIClean Sentinel refuses privileged execution\n"' "$SENTINEL_MAIN" \
  || fail "Sentinel root rejection diagnostic must remain fixed and path-free"
grep -Fq 'Darwin.write(STDERR_FILENO' "$SENTINEL_MAIN" \
  || fail "Sentinel root rejection must emit its fixed diagnostic directly to stderr"
grep -Fq '_exit(EX_NOPERM)' "$SENTINEL_MAIN" \
  || fail "Sentinel root rejection must exit immediately with EX_NOPERM"
sentinel_first_executable="$(awk '
  /^[[:space:]]*$/ { next }
  /^[[:space:]]*import[[:space:]]/ { next }
  /^[[:space:]]*\/\// { next }
  { print; exit }
' "$SENTINEL_MAIN")"
[ "$sentinel_first_executable" = 'if geteuid() == 0 {' ] \
  || fail "Sentinel root rejection must remain the first executable statement"
sentinel_root_guard_line="$(grep -nF 'if geteuid() == 0 {' "$SENTINEL_MAIN" | head -n 1 | cut -d: -f1)"
for sentinel_runtime_initializer in \
  'let log = SentinelLog.shared' \
  'FileManager.default' \
  'SentinelPaths.supportDirectory' \
  'TrashListener(dispatcher:' \
  'HotspotListener(ringBuffer:'; do
  sentinel_initializer_line="$(grep -nF "$sentinel_runtime_initializer" "$SENTINEL_MAIN" | head -n 1 | cut -d: -f1)"
  [ -n "$sentinel_initializer_line" ] \
    || fail "Sentinel runtime initializer disappeared: ${sentinel_runtime_initializer}"
  [ "$sentinel_root_guard_line" -lt "$sentinel_initializer_line" ] \
    || fail "Sentinel root rejection must precede: ${sentinel_runtime_initializer}"
done
/usr/bin/plutil -lint "$SENTINEL_AGENT_PLIST" >/dev/null \
  || fail "Sentinel LaunchAgent plist is not a valid property list"
sentinel_agent_program="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$SENTINEL_AGENT_PLIST")"
[ "$sentinel_agent_program" = 'Contents/MacOS/amuxaiclean-sentinel' ] \
  || fail "Sentinel LaunchAgent BundleProgram is unexpected"
sentinel_agent_label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$SENTINEL_AGENT_PLIST")"
[ "$sentinel_agent_label" = 'com.amux.ai.Clean.sentinel.agent' ] \
  || fail "Sentinel LaunchAgent label is unexpected"
if /usr/libexec/PlistBuddy -c 'Print :UserName' "$SENTINEL_AGENT_PLIST" >/dev/null 2>&1; then
  fail "Sentinel LaunchAgent must not hard-code UserName or root semantics"
fi
for daemon_contract in \
  "$SENTINEL_ORIGINAL_BRAND_DAEMON_PLIST|com.guoshuyu.cleanmac.sentinel" \
  "$SENTINEL_LEGACY_DAEMON_PLIST|com.amux.ai.Clean.sentinel"; do
  daemon_plist="${daemon_contract%%|*}"
  expected_label="${daemon_contract#*|}"
  /usr/bin/plutil -lint "$daemon_plist" >/dev/null \
    || fail "legacy Sentinel LaunchDaemon migration descriptor is not a valid property list: $(basename "$daemon_plist")"
  daemon_program="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$daemon_plist")"
  [ "$daemon_program" = 'Contents/MacOS/amuxaiclean-sentinel' ] \
    || fail "legacy Sentinel LaunchDaemon BundleProgram is unexpected: $(basename "$daemon_plist")"
  daemon_label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$daemon_plist")"
  [ "$daemon_label" = "$expected_label" ] \
    || fail "legacy Sentinel LaunchDaemon label is unexpected: $(basename "$daemon_plist")"
  [ "$(basename "$daemon_plist" .plist)" = "$daemon_label" ] \
    || fail "legacy Sentinel descriptor file name must match its Label: $(basename "$daemon_plist")"
  [ "$sentinel_agent_label" != "$daemon_label" ] \
    || fail "current agent and legacy daemon must not share a launchd label"
done
grep -Fq 'Contents/Library/LaunchAgents' "${PROJECT}/project.pbxproj" \
  || fail "Sentinel agent plist is not embedded under Contents/Library/LaunchAgents"
grep -Fq 'Embed LaunchAgents' "${PROJECT}/project.pbxproj" \
  || fail "Sentinel LaunchAgent copy phase is missing"
grep -Fq 'Contents/Library/LaunchDaemons' "${PROJECT}/project.pbxproj" \
  || fail "legacy Sentinel migration descriptor is not embedded under Contents/Library/LaunchDaemons"
grep -Fq 'Embed Legacy LaunchDaemon Migration Descriptor' "${PROJECT}/project.pbxproj" \
  || fail "legacy Sentinel migration copy phase is missing"
for daemon_plist_name in \
  com.guoshuyu.cleanmac.sentinel.plist \
  com.amux.ai.Clean.sentinel.plist; do
  [ "$(grep -Fc "${daemon_plist_name} in Embed Legacy LaunchDaemon Migration Descriptor" "${PROJECT}/project.pbxproj")" -ge 2 ] \
    || fail "legacy Sentinel migration descriptor is not referenced by the copy phase: ${daemon_plist_name}"
done
grep -Fq 'public nonisolated static let agentPlistName = "com.amux.ai.Clean.sentinel.agent.plist"' "$SENTINEL_MANAGER" \
  || fail "SentinelManager current-agent plist identity drifted"
grep -Fq '"com.amux.ai.Clean.sentinel.plist"' "$SENTINEL_MANAGER" \
  || fail "SentinelManager legacy daemon plist identity drifted"
grep -Fq '"com.guoshuyu.cleanmac.sentinel.plist"' "$SENTINEL_MANAGER" \
  || fail "SentinelManager original-brand daemon plist identity drifted"
grep -Fq 'label: "com.guoshuyu.cleanmac.sentinel"' "$SENTINEL_MANAGER" \
  || fail "SentinelManager original-brand daemon Label drifted"
grep -Fq 'label: "com.amux.ai.Clean.sentinel"' "$SENTINEL_MANAGER" \
  || fail "SentinelManager legacy daemon Label drifted"
grep -Fq 'service = SMAppService.agent(plistName: SentinelManager.agentPlistName)' "$SENTINEL_MANAGER" \
  || fail "SentinelManager does not register the current user agent"
grep -Fq 'SMAppService.daemon(plistName: descriptor.plistName)' "$SENTINEL_MANAGER" \
  || fail "SentinelManager does not construct every historical daemon descriptor"
grep -Fq 'try service.unregisterLegacyDaemon(descriptor)' "$SENTINEL_MANAGER" \
  || fail "SentinelManager lost the per-descriptor migration barrier"
grep -Fq 'try daemon.unregister()' "$SENTINEL_MANAGER" \
  || fail "SentinelManager does not unregister historical daemons"
if grep -Eq 'legacyDaemon[^[:cntrl:]]*\.[[:space:]]*register[[:space:]]*\(' "$SENTINEL_MANAGER"; then
  fail "legacy Sentinel LaunchDaemons must never be registered again"
fi
grep -Fq 'URLQueryItem(name: "path", value: path)' "$SENTINEL_MAIN" \
  || fail "Sentinel uninstall deep link must use URLQueryItem instead of manual query escaping"
grep -Fq 'repeating: Self.pruneCheckInterval' "$SENTINEL_MAIN" \
  || fail "Sentinel long-lived log retention timer is missing"

# v2026.07.18: release examples must not silently overwrite the project with last month's
# concrete version.
if grep -Eq 'VERSION=[0-9]+\.[0-9]+\.[0-9]+' \
  "${ROOT}/docs/RELEASE.md" "${ROOT}/docs/DEVELOPMENT.md" "${ROOT}/Scripts/build_release.sh"; then
  fail "release documentation/help contains a stale concrete VERSION example"
fi

# Discover every first-party manifest dynamically, excluding generated build trees.
# `dump-package` verifies SwiftPM semantics, so comments and formatting cannot pass it.
PACKAGE_MANIFESTS=()
while IFS= read -r -d '' manifest; do
  PACKAGE_MANIFESTS+=("$manifest")
done < <(
  find "${ROOT}/Packages" "${ROOT}/Tools" \
    -type d -name .build -prune -o -type f -name Package.swift -print0
)
[ "${#PACKAGE_MANIFESTS[@]}" -gt 0 ] || fail "no Swift package manifests discovered"

PACKAGE_DUMP="$(mktemp -t amuxaiclean-package-dump)"
for manifest in "${PACKAGE_MANIFESTS[@]}"; do
  relative_manifest="${manifest#"${ROOT}/"}"
  swift package --package-path "$(dirname "$manifest")" dump-package > "$PACKAGE_DUMP" \
    || fail "could not evaluate ${relative_manifest}"

  platform_index=0
  macos_version=""
  while platform_name="$(
    /usr/bin/plutil -extract "platforms.${platform_index}.platformName" raw \
      -o - "$PACKAGE_DUMP" 2>/dev/null
  )"; do
    if [ "$platform_name" = "macos" ]; then
      macos_version="$(
        /usr/bin/plutil -extract "platforms.${platform_index}.version" raw \
          -o - "$PACKAGE_DUMP" 2>/dev/null
      )"
      break
    fi
    platform_index=$((platform_index + 1))
  done
  [ "$macos_version" = "$DEPLOYMENT_TARGET" ] \
    || fail "${relative_manifest} declares macOS ${macos_version:-missing}, expected ${DEPLOYMENT_TARGET}"
done

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
assert_app_only_notarize_rejected() {
  if "$TARGET" "$@" >"$guard_output" 2>&1; then
    fail "$* unexpectedly succeeded"
  fi
  grep -Fq -- 'DMG-only' "$guard_output" \
    || fail "$* did not explain the DMG-only contract"
}
assert_app_only_notarize_rejected --notarize --app-only
assert_app_only_notarize_rejected --app-only --notarize

printf 'release contract passed: macOS %s floor, DMG-only notary order, final-byte remount proof, NUL-safe provenance, and final SHA256 verified\n' "$DEPLOYMENT_TARGET"
