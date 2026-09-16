#!/usr/bin/env bash
#
# ============================================
# Purpose:           Build, seed demo state, and capture the three App Store screenshots in the iPhone simulator.
# When to use:       Gate 10 — before uploading a new version's screenshots.
# Safe to run in prod?  Yes — simulator only; writes PNGs under build/.
# Owner:             Luke F. Walton
# ============================================
# Adapted from a-new-word-every-day@e829bcc9c0dc scripts/capture_app_store_screenshots.sh:
# iPhone only (TARGETED_DEVICE_FAMILY 1, no iPad set), English only, and three
# shots — the three tabs. The app honours the launch arguments in DEBUG builds:
#   -UITestSkipOnboarding   skip the first-run pages
#   -ScreenshotDemo         seed a few saved recipes + a list so screens aren't empty
#   -OpenTabRecipes / -OpenTabAdd   start on that tab (default is List)
#
# Output: build/app-store-screenshots/iphone/   6.5" (1284×2778)
#
# Requires: Xcode, iOS Simulator, fonts (scripts/fetch_fonts.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! compgen -G "RecipeToGroceryList/Resources/Fonts/*.ttf" > /dev/null 2>&1; then
  bash scripts/fetch_fonts.sh
fi

if [ -f project.local.yml ]; then
  bash scripts/generate.sh
else
  xcodegen generate
fi

pick_sim() {
  python3 - "$@" <<'PY'
import json, subprocess, sys
names = sys.argv[1:]
out = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
devices = json.loads(out)["devices"]
for want in names:
    for devs in devices.values():
        for d in devs:
            if d.get("isAvailable") and d["name"] == want:
                print(d["udid"])
                raise SystemExit
for want in names:
    for devs in devices.values():
        for d in devs:
            if d.get("isAvailable") and want in d["name"]:
                print(d["udid"])
                raise SystemExit
raise SystemExit(f"No simulator found for: {names}")
PY
}

BUNDLE="com.lukewalton.recipetogrocerylist"
BASE_ARGS=(-UITestSkipOnboarding -ScreenshotDemo)

# App Store Connect rejects PNGs with an alpha channel; round-trip through JPEG
# to flatten, then resize to the exact slot size.
flatten_png() {
  local src="$1" dest="$2" w="$3" h="$4"
  local tmp="${dest%.png}.jpg"
  sips -s format jpeg -s formatOptions 100 "$src" --out "$tmp" >/dev/null
  sips -s format png "$tmp" --out "$dest" >/dev/null
  rm -f "$tmp"
  sips -z "$h" "$w" "$dest" --out "$dest" >/dev/null
}

capture_set() {
  local sim_id="$1" out_dir="$2" w="$3" h="$4" label="$5"
  mkdir -p "$out_dir"

  echo ""
  echo "=== $label (${w}x${h}) — $sim_id ==="
  echo "Building for simulator..."
  xcodebuild build \
    -scheme RecipeToGroceryList \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$sim_id" \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=NO >/dev/null

  local app="build/DerivedData/Build/Products/Debug-iphonesimulator/RecipeToGroceryList.app"
  xcrun simctl boot "$sim_id" 2>/dev/null || true
  open -a Simulator --args -CurrentDeviceUDID "$sim_id"
  sleep 2
  xcrun simctl uninstall "$sim_id" "$BUNDLE" 2>/dev/null || true
  xcrun simctl install "$sim_id" "$app"

  capture_one() {
    local slug="$1"
    shift
    echo "→ $slug"
    xcrun simctl terminate "$sim_id" "$BUNDLE" 2>/dev/null || true
    sleep 0.4
    xcrun simctl launch "$sim_id" "$BUNDLE" -- "${BASE_ARGS[@]}" "$@"
    sleep 3.5
    local raw="/tmp/rtgl-${slug}-raw.png"
    xcrun simctl io "$sim_id" screenshot "$raw"
    flatten_png "$raw" "$out_dir/${slug}.png" "$w" "$h"
    rm -f "$raw"
    echo "  ✓ $out_dir/${slug}.png"
  }

  capture_one "01-list"
  capture_one "02-recipes" -OpenTabRecipes
  capture_one "03-add" -OpenTabAdd
}

IPHONE_SIM="${IPHONE_SIM:-$(pick_sim "iPhone 15 Pro Max" "iPhone 14 Plus" "iPhone 15 Plus" "iPhone 16 Plus")}"

capture_set "$IPHONE_SIM" "build/app-store-screenshots/iphone" 1284 2778 "iPhone 6.5\""

echo ""
echo "Done."
echo "  iPhone → build/app-store-screenshots/iphone/"
open build/app-store-screenshots
