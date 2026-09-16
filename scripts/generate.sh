#!/usr/bin/env bash
#
# ============================================
# Purpose:           Generate the Xcode project from project.yml (merging project.local.yml).
# When to use:       After cloning, or after changing project.yml / project.local.yml.
# Safe to run in prod?  Yes — local dev; regenerates the gitignored .xcodeproj.
# Owner:             Luke F. Walton
# ============================================
# Inherited unchanged from a-new-word-every-day@e829bcc9c0dc scripts/generate.sh:
# the merge step is what lets DEVELOPMENT_TEAM live in a gitignored file while
# project.yml stays the single committed source of truth that CI and the
# App Group / fonts guards read.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f project.local.yml ]; then
  cp project.local.yml.example project.local.yml
  echo "Created project.local.yml — set DEVELOPMENT_TEAM, then re-run this script."
  exit 1
fi

if grep -q 'YOUR_TEAM_ID_HERE' project.local.yml; then
  echo "Edit project.local.yml and replace YOUR_TEAM_ID_HERE with your Team ID." >&2
  echo "(or run: bash scripts/setup_signing.sh to detect it from this Mac)" >&2
  exit 1
fi

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "This script merges project.yml with project.local.yml using PyYAML." >&2
  echo "Install it first:  python3 -m pip install pyyaml" >&2
  exit 1
fi

# Merge project.yml + project.local.yml for XcodeGen (local file is gitignored).
python3 - <<'PY'
import yaml
from pathlib import Path

def deep_merge(base, override):
    for key, value in override.items():
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            deep_merge(base[key], value)
        else:
            base[key] = value

root = Path(".")
spec = yaml.safe_load(root.joinpath("project.yml").read_text())
local = yaml.safe_load(root.joinpath("project.local.yml").read_text())
deep_merge(spec, local)
root.joinpath("project.generated.yml").write_text(yaml.dump(spec, sort_keys=False))
PY

xcodegen generate --spec project.generated.yml
rm -f project.generated.yml
