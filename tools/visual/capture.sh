#!/usr/bin/env bash
#
# Capture simulator screenshots of every built screen, then diff them against
# the supplied references.
#
#   ./tools/visual/capture.sh [device-name]
#
# Screens are driven by the UI tests rather than by hand, so the capture always
# reflects the app a user would actually reach — a screenshot of a preview or a
# hand-placed view can look right while the real navigation into it is broken.
#
# Captures land in tools/visual/actual/, comparisons in tools/visual/output/.

set -euo pipefail

DEVICE="${1:-iPhone 17 Pro}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_DIR="$ROOT/app"
ACTUAL_DIR="$ROOT/tools/visual/actual"
RESULT_BUNDLE="$ROOT/tools/visual/.result.xcresult"

mkdir -p "$ACTUAL_DIR"
rm -rf "$RESULT_BUNDLE"

echo "==> Running UI tests to capture screenshots on $DEVICE"
xcodebuild test \
  -project "$APP_DIR/Moomo.xcodeproj" \
  -scheme Moomo \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -only-testing:MoomoUITests/OnboardingUITests/testCaptureWelcomeScreenshot \
  -only-testing:MoomoUITests/OnboardingUITests/testCaptureDiscoverScreenshot \
  -derivedDataPath "$APP_DIR/build/DerivedData" \
  -resultBundlePath "$RESULT_BUNDLE" \
  >/dev/null 2>&1 || echo "    (some capture tests failed — extracting whatever was captured)"

echo "==> Extracting attachments"
xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE" \
  --output-path "$ACTUAL_DIR" \
  >/dev/null 2>&1 || true

# xcresulttool names attachments by test; normalise to <screen>.png so the
# comparison script can pair them with the references.
python3 - "$ACTUAL_DIR" <<'PY'
import json, shutil, sys
from pathlib import Path

out = Path(sys.argv[1])
manifest = out / "manifest.json"
if not manifest.exists():
    sys.exit(0)

for entry in json.loads(manifest.read_text()):
    for attachment in entry.get("attachments", []):
        name = attachment.get("suggestedHumanReadableName", "")
        exported = attachment.get("exportedFileName")
        if not exported:
            continue
        source = out / exported
        if not source.exists():
            continue
        for screen in ("welcome", "discover", "speed-call", "call-ended", "match-chat", "profile"):
            if screen in name.lower():
                shutil.move(str(source), str(out / f"{screen}.png"))
                print(f"    captured {screen}.png")
                break
PY

echo "==> Comparing against references"
python3 "$ROOT/tools/visual/compare.py"
