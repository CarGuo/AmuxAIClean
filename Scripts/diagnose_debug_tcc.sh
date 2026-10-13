#!/usr/bin/env bash
#
# Diagnose why the Debug .app does not match an existing Full Disk Access grant.
#
# This script is read-only. It does not reset TCC, does not modify signing, and
# does not launch the app. If the current Terminal/Codex process lacks Full Disk
# Access, the TCC database section will say so explicitly.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="${ROOT}/AmuxAIClean.xcodeproj"
SCHEME="AmuxAIClean"
CONFIGURATION="Debug"

step() { printf "\n\033[1;36m[debug-tcc]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[debug-tcc]\033[0m %s\n" "$*" >&2; }

cd "$ROOT"

step "Resolve Debug product path"
BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null)"
BUILT_PRODUCTS_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR =/{print $2; exit}')"
FULL_PRODUCT_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*FULL_PRODUCT_NAME =/{print $2; exit}')"
PRODUCT_BUNDLE_IDENTIFIER="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER =/{print $2; exit}')"
CODE_SIGN_STYLE="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*CODE_SIGN_STYLE =/{print $2; exit}')"
CODE_SIGN_IDENTITY="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*CODE_SIGN_IDENTITY =/{print $2; exit}')"
DEVELOPMENT_TEAM="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*DEVELOPMENT_TEAM =/{print $2; exit}')"
ENABLE_DEBUG_DYLIB="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/^[[:space:]]*ENABLE_DEBUG_DYLIB =/{print $2; exit}')"
APP_PATH="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}"

printf 'project: %s\n' "$PROJECT"
printf 'scheme: %s\n' "$SCHEME"
printf 'configuration: %s\n' "$CONFIGURATION"
printf 'app: %s\n' "$APP_PATH"
printf 'bundle id: %s\n' "$PRODUCT_BUNDLE_IDENTIFIER"
printf 'sign style: %s\n' "$CODE_SIGN_STYLE"
printf 'sign identity setting: %s\n' "$CODE_SIGN_IDENTITY"
printf 'development team: %s\n' "$DEVELOPMENT_TEAM"
printf 'enable debug dylib: %s\n' "${ENABLE_DEBUG_DYLIB:-<unset>}"

if [ ! -d "$APP_PATH" ]; then
    warn "Debug app does not exist yet. Run ./Scripts/run_debug.sh once, then rerun this script."
    exit 3
fi

step "Bundle metadata"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP_PATH}/Contents/Info.plist" 2>/dev/null | sed 's/^/CFBundleIdentifier: /' || true
/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "${APP_PATH}/Contents/Info.plist" 2>/dev/null | sed 's/^/CFBundleName: /' || true
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist" 2>/dev/null | sed 's/^/CFBundleVersion: /' || true

step "Code signature summary"
codesign -dv --verbose=4 "$APP_PATH" 2>&1 \
  | awk '/Identifier=|Authority=|TeamIdentifier=|CDHash=|Signature=|Timestamp=|Runtime Version=|Sealed Resources version=|Internal requirements count=|flags=/{print}'

step "Designated requirement used by TCC matching"
codesign -d -r- "$APP_PATH" 2>&1 || true

step "Entitlements"
if ! codesign -d --entitlements :- "$APP_PATH" 2>/dev/null; then
    warn "No entitlements were emitted by codesign."
fi

step "TCC database entries for this bundle id"
TCC_DB="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
if [ ! -r "$TCC_DB" ]; then
    warn "Cannot read ${TCC_DB}. Give Terminal/Codex Full Disk Access if you want this section populated."
else
    sqlite3 -header -column "$TCC_DB" "
      SELECT
        service,
        client,
        client_type,
        auth_value,
        auth_reason,
        auth_version,
        datetime(last_modified, 'unixepoch', 'localtime') AS modified
      FROM access
      WHERE client = '${PRODUCT_BUNDLE_IDENTIFIER}'
         OR client LIKE '%AmuxAIClean%'
         OR service = 'kTCCServiceSystemPolicyAllFiles'
      ORDER BY modified DESC, service, client;
    " || warn "sqlite3 could not query TCC.db."
fi

cat <<EOF

Next checks:
  1. Run this script, grant Full Disk Access to the exact Debug app above, fully quit the app.
  2. Rebuild with ./Scripts/run_debug.sh, then run this script again.
  3. If the designated requirement or Authority changed, Debug automatic signing is not stable enough for TCC.
  4. If the TCC row exists but the app still reports denied, the app-side FDA probe/banner is the suspect.
EOF
