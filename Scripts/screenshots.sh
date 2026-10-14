#!/usr/bin/env bash
# v2026.10.14: use production views and temp fixtures; retire guessed sidebar
# positions and whole-desktop fallback capture. No App launch or C4/C5 claim.
set -euo pipefail

CAPTURE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CAPTURE_OUTPUT="${CAPTURE_ROOT}/docs/screenshots"
CAPTURE_BUILD="${CAPTURE_ROOT}/build/documentation-capture/spm"

if [[ $# -gt 0 ]]; then
    case "$1" in
        --help|-h)
            printf '%s\n' 'Usage: Scripts/screenshots.sh [--output-dir PATH]' \
                'Renders current production views in zh-Hans and en with example data.' \
                'No App launch, HOME scan, deletion, AI request or permission change.'
            exit 0 ;;
        --output-dir)
            [[ $# -eq 2 ]] || { printf '%s\n' 'Expected one output directory.' >&2; exit 2; }
            CAPTURE_OUTPUT="$2" ;;
        *) printf '%s\n' 'Use --help for supported options.' >&2; exit 2 ;;
    esac
fi
mkdir -p "$CAPTURE_OUTPUT"
CAPTURE_OUTPUT="$(cd "$CAPTURE_OUTPUT" && pwd)"

AMUXCLEAN_DOCUMENTATION_RENDER_DIR="$CAPTURE_OUTPUT" \
swift test --package-path "${CAPTURE_ROOT}/Packages/AppUI" \
    --scratch-path "$CAPTURE_BUILD" \
    --filter DocumentationScreenshotTests

python3 - "$CAPTURE_ROOT" "$CAPTURE_OUTPUT" <<'PYMETA'
from pathlib import Path
import datetime, hashlib, json, subprocess, sys
root, output = map(Path, sys.argv[1:])
scenes = ['01-analyze','02-clean','03-status','04-tree','05-large-files','06-row-actions']
images = []
for scene in scenes:
    for language in ['zh-Hans','en']:
        path = output / (scene + '-' + language + '.jpg')
        data = path.read_bytes()
        if not data.startswith(b'\xff\xd8\xff'):
            raise SystemExit('Not a JPEG: ' + str(path))
        images.append({'file': path.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
head = subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()
manifest = {
    'schemaVersion': 1,
    'kind': 'offscreen-production-views-with-examples',
    'generatedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'checkoutHead': head,
    'generator': 'Packages/AppUI/Tests/AppUITests/DocumentationScreenshotTests.swift',
    'generatorSHA256': hashlib.sha256((root/'Packages/AppUI/Tests/AppUITests/DocumentationScreenshotTests.swift').read_bytes()).hexdigest(),
    'appLaunched': False,
    'realHomeScanned': False,
    'filesRecycled': False,
    'aiRequested': False,
    'statusData': 'read-only capture-machine measurements',
    'images': images,
}
(output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
PYMETA

printf '%s\n' "Documentation images: ${CAPTURE_OUTPUT}" \
    'See docs/screenshots/README.md for data and evidence boundaries.'
