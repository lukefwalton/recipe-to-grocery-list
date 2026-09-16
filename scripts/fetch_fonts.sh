#!/usr/bin/env bash
#
# ============================================
# Purpose:           Download the OFL 1.1 variable fonts into RecipeToGroceryList/Resources/Fonts/.
# When to use:       Before a release build, or any build that needs the bundled fonts.
# Safe to run in prod?  Yes — network download into a gitignored local folder; nothing committed.
# Owner:             Luke F. Walton
# ============================================
#
# Adapted from a-new-word-every-day@e829bcc9c0dc scripts/fetch_fonts.sh with the
# list trimmed to the two faces this app uses (SPEC §3: "Only Fraunces and Inter
# are needed here"). Same URLs as the word repo so both apps ship the same masters.
#
# The fonts are NOT committed (kept out of git via .gitignore) to keep the repo
# light and avoid vendoring binaries; this script downloads the variable .ttf
# masters straight from each typeface's source repo. Both are SIL Open Font
# License 1.1 — free to embed in an app binary; we ship OFL.txt + an in-app
# Acknowledgements credit. The app runs without them too: the typography layer
# falls back to a system serif/sans (see LFWTypography), so onboarding and tests
# don't depend on this step.
#
# Run from anywhere:  bash scripts/fetch_fonts.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="RecipeToGroceryList/Resources/Fonts"
mkdir -p "$DEST"

# name|url  (variable masters; the family's runtime name must match LFWTypeface.family)
# scripts/check_fonts_sync.sh reads this list and compares it with Info.plist's
# UIAppFonts and Theme.bundledTypefaces — change all three together.
FONTS=(
  "Fraunces.ttf|https://github.com/undercasetype/Fraunces/raw/master/fonts/variable/Fraunces%5BSOFT%2CWONK%2Copsz%2Cwght%5D.ttf"
  "Inter.ttf|https://github.com/rsms/inter/raw/master/docs/font-files/InterVariable.ttf"
)

# NOTE: URLs point at each font's source branch (master/main), which can move.
# For a reproducible setup, pin to a release asset or commit SHA and verify a
# checksum. We fail non-zero on ANY download problem so a partial fetch can't
# look successful.
failed=0
for entry in "${FONTS[@]}"; do
  name="${entry%%|*}"
  url="${entry#*|}"
  echo "↓ $name"
  # Retry transient failures (GitHub's raw host rate-limits with HTTP 429 under
  # load, which would otherwise fail the whole job before anything builds).
  # --retry-all-errors covers 429; curl backs off exponentially and honours any
  # Retry-After header.
  if curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors "$url" -o "$DEST/$name"; then
    echo "  ✓ $DEST/$name"
  else
    echo "  ✗ failed — update the URL in scripts/fetch_fonts.sh (source repos move files)" >&2
    rm -f "$DEST/$name"   # don't leave a truncated/partial file behind
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  echo "One or more fonts failed to download. The app still runs (system fallback)," >&2
  echo "but fix the URLs above before relying on the bundled typefaces." >&2
  exit 1
fi

cat <<'NOTE'

Done. Next:
  1. Confirm the runtime family names (a VF registers under its default named
     instance). In a debug build, LFWVariableFont.axes(of: "Fraunces") logs the
     real family + axes — if it's empty, fix LFWTypeface.family / UIAppFonts.
  2. The font files are already listed in RecipeToGroceryList/App/Info.plist
     (UIAppFonts) and bundled via the Resources group in project.yml; the theme
     picker is limited to these two by Theme.bundledTypefaces.
NOTE
