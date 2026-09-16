#!/usr/bin/env bash
#
# ============================================
# Purpose:           Regenerate the bundled ingredient seed (Resources/seed_ingredients.json) from scripts/seed_source.json.
# When to use:       After editing scripts/seed_source.json. Pass --check to only verify (CI does this).
# Safe to run in prod?  Yes — deterministic; only rewrites the generated output.
# Owner:             Luke F. Walton
# ============================================
# Thin wrapper, same shape as a-new-word-every-day/scripts/build_corpus.sh (@e829bcc9c0dc).
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/build_seed.py "$@"
