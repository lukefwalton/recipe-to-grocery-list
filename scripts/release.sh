#!/usr/bin/env bash
#
# ============================================
# Purpose:           Fetch fonts, run tests, and archive a Release build for App Store upload.
# When to use:       When cutting an App Store build.
# Safe to run in prod?  Yes, with caution — produces the shippable archive; run on a clean, signed checkout.
# Owner:             Luke F. Walton
# ============================================
# Adapted from a-new-word-every-day@e829bcc9c0dc scripts/release.sh. The order
# (fonts → project → tests → archive) is deliberate: fonts must exist before the
# project is generated or the archive ships without them.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Fonts"
if ! compgen -G "RecipeToGroceryList/Resources/Fonts/*.ttf" > /dev/null; then
  bash scripts/fetch_fonts.sh
fi

echo "==> Project"
if [ -f project.local.yml ]; then
  bash scripts/generate.sh
else
  echo "Create project.local.yml with your DEVELOPMENT_TEAM first." >&2
  echo "  cp project.local.yml.example project.local.yml" >&2
  echo "  bash scripts/setup_signing.sh   # auto-detect team" >&2
  exit 1
fi

echo "==> Tests"
bash scripts/run_tests.sh

ARCHIVE="${1:-build/RecipeToGroceryList.xcarchive}"
mkdir -p "$(dirname "$ARCHIVE")"

echo "==> Archive (Release) → $ARCHIVE"
xcodebuild archive \
  -scheme RecipeToGroceryList \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates

echo ""
echo "Done. Next steps:"
echo "  1. Xcode → Window → Organizer → Distribute App"
echo "  2. App Store Connect: Support URL → https://lukefwalton.com/recipe-to-grocery-list/"
echo "  3. Privacy Policy URL → https://lukefwalton.com/recipe-to-grocery-list/privacy/"
echo "  4. App Privacy: Data Not Collected"
echo "  5. Screenshots: bash scripts/capture_app_store_screenshots.sh (List, Recipes, Add)"
echo "  6. Subtitle: never put Free/price in name, subtitle or promo text — Guideline 2.3.7"
echo "  7. See docs/app-store-metadata.md for compliant copy (and the 1.0 checklist)"
echo "  8. Review notes: docs/app-store-review-notes.md — no login; one page fetch per link;"
echo "     works with camera denied and without Apple Intelligence"
echo "  9. Replace the placeholder app icon (AppIcon-1024.png) before submitting"
