#!/usr/bin/env bash
#
# ============================================
# Purpose:           Archive a Release build for TestFlight / App Store (no tests, no font check).
# When to use:       Gate 10 — a quick archive when release.sh's full run is not needed.
# Safe to run in prod?  Yes, with caution — produces the shippable archive; sign with your own team.
# Owner:             Luke F. Walton
# ============================================
# Adapted from workout-logger@5bffddfb80fc scripts/archive_for_testflight.sh
# (scheme renamed; fonts fetched first because this app bundles OFL typefaces
# that are gitignored — an archive generated without them ships system fonts).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! compgen -G "RecipeToGroceryList/Resources/Fonts/*.ttf" > /dev/null; then
  bash scripts/fetch_fonts.sh
fi

bash scripts/generate.sh

ARCHIVE="build/RecipeToGroceryList.xcarchive"
mkdir -p build

echo "Archiving for App Store / TestFlight..."
xcodebuild archive \
  -scheme RecipeToGroceryList \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration

echo ""
echo "Archive ready: $ARCHIVE"
echo "Upload via Xcode Organizer (Product → Archive), or export the .ipa for Transporter with:"
echo "  xcodebuild -exportArchive -archivePath $ARCHIVE -exportPath build/export -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates"
