#!/usr/bin/env bash
#
# Read-only fixture capture for common app cache rules.
#
# This script gathers evidence for apps whose macOS cache paths should not be
# guessed. It does not delete or modify files. The output is intended for rule
# review before adding entries to Resources/Rules/vendors.yaml.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${ROOT}/Tests/Fixtures/common-app-cache"
WITH_SIZE=0

DEFAULT_QUERIES=(
    "Feishu"
    "Lark"
    "DingTalk"
    "QQ"
    "TIM"
    "WeCom"
    "企业微信"
    "WPS"
    "Kingsoft"
    "BaiduNetdisk"
    "百度网盘"
    "AliyunDrive"
    "阿里云盘"
    "Quark"
    "夸克"
    "115"
    "NetEaseMusic"
    "网易云音乐"
    "iQIYI"
    "爱奇艺"
    "Youku"
    "优酷"
)

usage() {
    cat <<'EOF'
Usage:
  Scripts/capture_app_cache_fixture.sh [--out DIR] [--with-size] [app name ...]

Examples:
  Scripts/capture_app_cache_fixture.sh
  Scripts/capture_app_cache_fixture.sh --out /tmp/amux-fixtures Feishu DingTalk WPS
  Scripts/capture_app_cache_fixture.sh --with-size Lark QQ WeCom

Notes:
  - Read-only. No file is deleted or modified.
  - Without app names, a domestic-app candidate set is used.
  - App discovery intentionally matches top-level app bundle names only; no
    recursive /Applications traversal or Spotlight query runs by default.
  - --with-size runs du on matched candidate paths, which may be slow for large
    caches. Leave it off when collecting quick bundle/path evidence.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        --with-size)
            WITH_SIZE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [ $# -gt 0 ]; then
    QUERIES=("$@")
else
    QUERIES=("${DEFAULT_QUERIES[@]}")
fi

plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().rstrip("\n")))'
}

path_size_kb() {
    local path="$1"
    if [ "$WITH_SIZE" -eq 0 ]; then
        printf 'null'
        return
    fi
    du -sk "$path" 2>/dev/null | awk '{print $1}' || printf 'null'
}

path_kind() {
    local path="$1"
    if [ -d "$path" ]; then
        printf 'directory'
    elif [ -f "$path" ]; then
        printf 'file'
    else
        printf 'other'
    fi
}

add_candidate() {
    local path="$1"
    [ -e "$path" ] || return 0
    printf '%s\n' "$path" >> "$CANDIDATE_TMP"
}

mkdir -p "$OUT_DIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
JSON_OUT="${OUT_DIR}/common-app-cache-fixture-${STAMP}.jsonl"
MD_OUT="${OUT_DIR}/common-app-cache-fixture-${STAMP}.md"
CANDIDATE_TMP="$(mktemp -t amux-candidates.XXXXXX)"
MATCHED_APP_TMP="$(mktemp -t amux-matched-apps.XXXXXX)"
trap 'rm -f "$CANDIDATE_TMP" "$MATCHED_APP_TMP"' EXIT

append_app_glob_matches() {
    local base="$1"
    local query="$2"
    [ -d "$base" ] || return 0
    local app
    for app in "$base"/*"$query"*.app; do
        [ -d "$app" ] || continue
        printf '%s\n' "$app"
    done
}

{
    printf '# Common App Cache Fixture\n\n'
    printf -- '- Captured at: `%s`\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '- Size mode: `%s`\n\n' "$([ "$WITH_SIZE" -eq 1 ] && printf enabled || printf disabled)"
    printf '## Matched Apps\n\n'
} > "$MD_OUT"

: > "$JSON_OUT"

for query in "${QUERIES[@]}"; do
    : > "$MATCHED_APP_TMP"
    append_app_glob_matches /Applications "$query" >> "$MATCHED_APP_TMP"
    append_app_glob_matches "$HOME/Applications" "$query" >> "$MATCHED_APP_TMP"
    sort -u "$MATCHED_APP_TMP" > "${MATCHED_APP_TMP}.sorted"
    mv "${MATCHED_APP_TMP}.sorted" "$MATCHED_APP_TMP"

    while IFS= read -r app; do
        [ -n "$app" ] || continue
        plist="${app}/Contents/Info.plist"
        [ -f "$plist" ] || continue
        bundle_id="$(plist_value "$plist" CFBundleIdentifier)"
        name="$(plist_value "$plist" CFBundleName)"
        display_name="$(plist_value "$plist" CFBundleDisplayName)"
        executable="$(plist_value "$plist" CFBundleExecutable)"

        : > "$CANDIDATE_TMP"
        tokens=()
        [ -n "$bundle_id" ] && tokens+=("$bundle_id")
        [ -n "$name" ] && tokens+=("$name")
        [ -n "$display_name" ] && tokens+=("$display_name")
        [ -n "$executable" ] && tokens+=("$executable")

        for token in "${tokens[@]}"; do
            [ -n "$token" ] || continue
            add_candidate "$HOME/Library/Caches/$token"
            add_candidate "$HOME/Library/Logs/$token"
            add_candidate "$HOME/Library/Application Support/$token"
            add_candidate "$HOME/Library/HTTPStorages/$token"
            add_candidate "$HOME/Library/WebKit/$token"
            add_candidate "$HOME/Library/Containers/$token/Data/Library/Caches"
            add_candidate "$HOME/Library/Containers/$token/Data/Library/Logs"
            add_candidate "$HOME/Library/Containers/$token/Data/Library/Application Support"
        done

        if [ -n "$bundle_id" ]; then
            find "$HOME/Library/Caches" \
                 "$HOME/Library/Logs" \
                 "$HOME/Library/Application Support" \
                 "$HOME/Library/Containers" \
                 "$HOME/Library/Group Containers" \
                 -maxdepth 2 -iname "*${bundle_id}*" -print 2>/dev/null >> "$CANDIDATE_TMP" || true
        fi

        sort -u "$CANDIDATE_TMP" > "${CANDIDATE_TMP}.sorted"
        mv "${CANDIDATE_TMP}.sorted" "$CANDIDATE_TMP"

        printf '### %s\n\n' "${display_name:-${name:-$query}}" >> "$MD_OUT"
        printf -- '- App: `%s`\n' "$app" >> "$MD_OUT"
        printf -- '- Bundle ID: `%s`\n' "${bundle_id:-unknown}" >> "$MD_OUT"
        printf -- '- Matched query: `%s`\n\n' "$query" >> "$MD_OUT"
        printf '| Candidate path | Kind | Size KB |\n| --- | --- | ---: |\n' >> "$MD_OUT"

        if [ ! -s "$CANDIDATE_TMP" ]; then
            printf '| _No matching Library candidates found_ | - | - |\n\n' >> "$MD_OUT"
        fi

        while IFS= read -r candidate; do
            kind="$(path_kind "$candidate")"
            size_kb="$(path_size_kb "$candidate")"
            printf '| `%s` | %s | %s |\n' "$candidate" "$kind" "$size_kb" >> "$MD_OUT"
            printf '{"query":%s,"app":%s,"bundleID":%s,"path":%s,"kind":%s,"sizeKB":%s}\n' \
                "$(printf '%s' "$query" | json_escape)" \
                "$(printf '%s' "$app" | json_escape)" \
                "$(printf '%s' "$bundle_id" | json_escape)" \
                "$(printf '%s' "$candidate" | json_escape)" \
                "$(printf '%s' "$kind" | json_escape)" \
                "$size_kb" >> "$JSON_OUT"
        done < "$CANDIDATE_TMP"
        printf '\n' >> "$MD_OUT"
    done < "$MATCHED_APP_TMP"
done

printf 'Wrote:\n  %s\n  %s\n' "$MD_OUT" "$JSON_OUT"
