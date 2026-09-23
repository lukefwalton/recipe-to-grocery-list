#!/usr/bin/env bash
#
# ============================================
# Purpose:           Verify the App Group id matches between project.yml and Shared/AppGroup.swift.
# When to use:       In CI, and before committing entitlement or App Group changes.
# Safe to run in prod?  Yes — read-only validation, makes no writes.
# Owner:             Luke F. Walton
# ============================================
#
# Adapted from a-new-word-every-day@e829bcc9c0dc scripts/check_appgroup_sync.sh
# (Swift path and the widget wording changed; the logic is identical).
#
# Keeps the App Group identifier in sync between the two places that declare it
# and can't see each other: project.yml's com.apple.security.application-groups
# entitlements (the build side, consumed by XcodeGen) and AppGroup.identifier in
# Swift (the runtime side). A mismatch can't be caught at compile time and would
# leave the Share Extension writing its inbox into a container the app never
# reads — every share would silently vanish. project.yml legitimately lists the
# SAME group under two targets (app + extension); the check requires exactly one
# DISTINCT value, and that it equals the Swift constant. Exits non-zero if they
# disagree or either side is missing.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$ROOT/project.yml"
APP_GROUP_SWIFT="$ROOT/RecipeToGroceryList/Shared/AppGroup.swift"

# All `- group.…` items under any `application-groups:` block, block-scoped, unique.
YAML_IDS=()
while IFS= read -r id; do
  YAML_IDS+=("$id")
done < <(awk '
  match($0, /^[ ]*/) { indent = RLENGTH }
  /application-groups:[[:space:]]*$/ { in_block = 1; key_indent = indent; next }
  in_block && $0 ~ /^[[:space:]]*-[[:space:]]*group\./ {
    v = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", v); gsub(/[[:space:]"]/, "", v); print v; next
  }
  in_block && $0 ~ /[^[:space:]]/ && indent <= key_indent { in_block = 0 }
' "$PROJECT_YML" | sort -u)

if [[ ! -f "$APP_GROUP_SWIFT" ]]; then
  echo "❌ Missing $APP_GROUP_SWIFT — the runtime side of the App Group identifier"
  exit 1
fi

# The literal assigned to `AppGroup.identifier`, anchored to the assignment.
SWIFT_ID="$(grep -oE 'static let identifier[[:space:]]*=[[:space:]]*"[^"]*"' "$APP_GROUP_SWIFT" \
            | grep -oE 'group\.[A-Za-z0-9._-]+' | head -1)"

if [[ ${#YAML_IDS[@]} -eq 0 ]]; then
  echo "❌ No App Group found under an application-groups: block in $PROJECT_YML"
  exit 1
fi
if [[ -z "$SWIFT_ID" ]]; then
  echo "❌ No AppGroup.identifier = \"group.…\" assignment found in $APP_GROUP_SWIFT"
  exit 1
fi
if [[ ${#YAML_IDS[@]} -gt 1 ]]; then
  echo "❌ Multiple distinct App Groups in $PROJECT_YML; the app and the Share Extension must share one:"
  printf '   %s\n' "${YAML_IDS[@]}"
  exit 1
fi
if [[ "${YAML_IDS[0]}" != "$SWIFT_ID" ]]; then
  echo "❌ App Group identifier drift:"
  echo "   project.yml entitlement : ${YAML_IDS[0]}"
  echo "   AppGroup.identifier      : $SWIFT_ID"
  echo "   These must match — the extension writes inbox.json where the app looks for it."
  exit 1
fi

echo "✅ App Group identifier in sync: $SWIFT_ID"
