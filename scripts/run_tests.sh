#!/usr/bin/env bash
#
# ============================================
# Purpose:           Generate the project and run the Swift unit suite on a simulator.
# When to use:       Before pushing, and to reproduce CI locally.
# Safe to run in prod?  Yes — builds and tests only; no release side effects.
# Owner:             Luke F. Walton
# ============================================
# Adapted from a-new-word-every-day@e829bcc9c0dc scripts/run_tests.sh (scheme and
# fonts directory renamed; no widget here).
set -euo pipefail
cd "$(dirname "$0")/.."

# Variable fonts are gitignored; fetch BEFORE generating. The Resources group is
# enumerated at generate time (not a folder reference), so a project generated
# without the .ttf files on disk silently leaves them out of the bundle.
if ! compgen -G "RecipeToGroceryList/Resources/Fonts/*.ttf" > /dev/null; then
  bash scripts/fetch_fonts.sh
fi

# Generate the same project you build locally: if project.local.yml exists, go
# through the merge flow (team/bundle overrides) rather than a bare xcodegen,
# so tests run against the same generated project as `scripts/generate.sh`.
if [ -f project.local.yml ]; then
  bash scripts/generate.sh
else
  xcodegen generate
fi

# xcodebuild's `name=iPhone 15` destination uses OS:latest, which often fails
# when multiple runtimes expose the same device name. Always pin a UDID instead.
DEST=$(python3 <<'PY'
import json, subprocess

def pick():
    out = subprocess.check_output(
        ["xcrun", "simctl", "list", "devices", "available", "-j"], text=True
    )
    devices = json.loads(out)["devices"]
    iphones = []
    for runtime, devs in devices.items():
        for d in devs:
            if d.get("isAvailable") and d["name"].startswith("iPhone"):
                iphones.append(d)
    if not iphones:
        return None
    for preferred in ("iPhone 15", "iPhone 16", "iPhone 17"):
        for d in iphones:
            if d["name"] == preferred:
                return d["udid"]
    return iphones[0]["udid"]

udid = pick()
if not udid:
    raise SystemExit("No iPhone simulator found")
print(f"platform=iOS Simulator,id={udid}")
PY
)

xcodebuild test \
  -scheme RecipeToGroceryList \
  -destination "$DEST" \
  CODE_SIGNING_ALLOWED=NO
