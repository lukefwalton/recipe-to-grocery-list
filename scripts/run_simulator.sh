#!/usr/bin/env bash
#
# ============================================
# Purpose:           Build Debug, install and launch the app on an iPhone simulator.
# When to use:       Quick manual QA without opening Xcode.
# Safe to run in prod?  Yes — simulator only; no signing, no release side effects.
# Owner:             Luke F. Walton
# ============================================
# Adapted from workout-logger@5bffddfb80fc scripts/run_simulator.sh. The
# hard-coded machine-specific UDID became an optional SIM_UDID override; the
# fallback picks the first available iPhone the same way the sibling did.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! compgen -G "RecipeToGroceryList/Resources/Fonts/*.ttf" > /dev/null; then
  bash scripts/fetch_fonts.sh
fi

if [ -f project.local.yml ]; then
  bash scripts/generate.sh
else
  xcodegen generate
fi

BUNDLE="com.lukewalton.recipetogrocerylist"
SIM_ID="${SIM_UDID:-}"
if [ -z "$SIM_ID" ] || ! xcrun simctl list devices available | grep -q "$SIM_ID"; then
  SIM_ID=$(xcrun simctl list devices available --json \
    | python3 -c "import json,sys; r=json.load(sys.stdin)['devices']; ids=[d['udid'] for ds in r.values() for d in ds if d['name'].startswith('iPhone') and d.get('isAvailable', True)]; print(ids[0] if ids else '')")
  if [ -z "$SIM_ID" ]; then
    echo "No iPhone simulator found" >&2
    exit 1
  fi
fi
DEST="platform=iOS Simulator,id=$SIM_ID"

echo "Building Debug for simulator..."
xcodebuild build \
  -scheme RecipeToGroceryList \
  -destination "$DEST" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO

APP=$(xcodebuild -showBuildSettings -scheme RecipeToGroceryList -destination "$DEST" -configuration Debug 2>/dev/null \
  | awk -F' = ' '/TARGET_BUILD_DIR/ {dir=$2} /FULL_PRODUCT_NAME/ {name=$2} END {print dir"/"name}')

xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_ID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl launch "$SIM_ID" "$BUNDLE"
open -a Simulator

echo "Launched on simulator."
