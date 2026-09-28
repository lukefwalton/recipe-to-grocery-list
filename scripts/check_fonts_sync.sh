#!/usr/bin/env bash
#
# ============================================
# Purpose:           Verify the bundled typeface list matches across the app's Swift allowlist, Info.plist, and fetch_fonts.sh.
# When to use:       In CI, and after changing the set of bundled fonts.
# Safe to run in prod?  Yes — read-only validation, makes no writes.
# Owner:             Luke F. Walton
# ============================================
#
# Adapted from a-new-word-every-day@e829bcc9c0dc scripts/check_fonts_sync.sh. The
# word app bundles every LFWTypeface, so its check compares the design system's
# full list against the plists. This app bundles only two of them (SPEC §3) and
# limits the theme picker to those two via `Theme.bundledTypefaces` — offering a
# face that isn't bundled would render as a silent system fallback. So the
# source of truth here is the APP's allowlist, and three things must agree:
#
#   1. RecipeToGroceryList/App/Theme.swift
#        `static let bundledTypefaces: [LFWTypeface] = [.fraunces, .inter]`
#      Each case is mapped to its file through LFWTypeface.bundledFileName in the
#      vendored lfwdesignsystem (the `case .NAME: return "FILE.ttf"` lines).
#   2. scripts/fetch_fonts.sh — the files actually downloaded.
#   3. RecipeToGroceryList/App/Info.plist — UIAppFonts, what iOS registers.
#
# Additionally every file named in 2 and 3 must be one the design system knows
# (a typo like "Interr.ttf" is caught even if it were consistent everywhere).
# No widget here, so no widget plist and no project.yml UIAppFonts block.
#
# Exits non-zero if any list disagrees or a source file is missing. Avoids
# bash-4-only features (associative arrays, mapfile) so it also runs under the
# bash 3.2 that macOS ships.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LFW_THEME="$ROOT/lfwdesignsystem/Sources/LFWDesignSystem/LFWTheme.swift"
APP_THEME="$ROOT/RecipeToGroceryList/App/Theme.swift"
FETCH_SCRIPT="$ROOT/scripts/fetch_fonts.sh"
APP_PLIST="$ROOT/RecipeToGroceryList/App/Info.plist"

for f in "$LFW_THEME" "$APP_THEME" "$FETCH_SCRIPT" "$APP_PLIST"; do
  if [[ ! -f "$f" ]]; then
    echo "❌ Missing $f — cannot check the bundled typeface list"
    exit 1
  fi
done

# "case file" pairs from LFWTypeface.bundledFileName, e.g. "fraunces Fraunces.ttf".
lfw_map() {
  awk '/public var bundledFileName: String \{/,/^    \}/ {
    if (match($0, /case \./)) print $0
  }' "$LFW_THEME" \
    | sed -n 's/.*case \.\([A-Za-z0-9_]*\):[[:space:]]*return "\([^"]*\.ttf\)".*/\1 \2/p'
}

lfw_file_for_case() {
  lfw_map | awk -v c="$1" '$1 == c { print $2; exit }'
}

# The case names inside the brackets of the allowlist line, one per line.
app_cases() {
  grep -E 'static let bundledTypefaces[[:space:]]*:[[:space:]]*\[LFWTypeface\][[:space:]]*=[[:space:]]*\[' "$APP_THEME" \
    | head -1 \
    | sed -n 's/.*=[[:space:]]*\[\(.*\)\].*/\1/p' \
    | grep -oE '\.[A-Za-z0-9_]+' \
    | tr -d '.' || true
}

fetch_fonts() {
  grep -oE '"[^"]+\.ttf\|' "$FETCH_SCRIPT" | tr -d '"|' | sort
}

plist_fonts() {
  grep '\.ttf</string>' "$1" \
    | sed -n 's/.*<string>\([^<]*\.ttf\)<\/string>.*/\1/p' \
    | sort
}

LFW_FILES=()
while IFS= read -r line; do LFW_FILES+=("${line#* }"); done < <(lfw_map)
if [[ ${#LFW_FILES[@]} -eq 0 ]]; then
  echo "❌ No bundledFileName entries found in $LFW_THEME"
  exit 1
fi

APP_CASES=()
while IFS= read -r line; do [[ -n "$line" ]] && APP_CASES+=("$line"); done < <(app_cases)
if [[ ${#APP_CASES[@]} -eq 0 ]]; then
  echo "❌ No 'static let bundledTypefaces: [LFWTypeface] = [.a, .b]' allowlist found in $APP_THEME"
  exit 1
fi

# Map the app's cases to files through the design system.
EXPECTED=()
for c in "${APP_CASES[@]}"; do
  f="$(lfw_file_for_case "$c")"
  if [[ -z "$f" ]]; then
    echo "❌ Theme.bundledTypefaces lists .$c, but LFWTypeface.bundledFileName has no such case"
    echo "   Known cases: $(lfw_map | awk '{printf ".%s ", $1}')"
    exit 1
  fi
  EXPECTED+=("$f")
done
SORTED_EXPECTED=()
while IFS= read -r line; do SORTED_EXPECTED+=("$line"); done < <(printf '%s\n' "${EXPECTED[@]}" | sort)
if [[ ${#SORTED_EXPECTED[@]} -ne $(printf '%s\n' "${SORTED_EXPECTED[@]}" | sort -u | wc -l | tr -d ' ') ]]; then
  echo "❌ Theme.bundledTypefaces lists a typeface twice: ${APP_CASES[*]}"
  exit 1
fi

FETCH_FONTS=()
while IFS= read -r line; do FETCH_FONTS+=("$line"); done < <(fetch_fonts)

APP_FONTS=()
while IFS= read -r line; do APP_FONTS+=("$line"); done < <(plist_fonts "$APP_PLIST")

compare_lists() {
  local label="$1"
  shift
  local -a other=("$@")
  if [[ ${#SORTED_EXPECTED[@]} -ne ${#other[@]} ]]; then
    echo "❌ Font count mismatch: Theme.bundledTypefaces has ${#SORTED_EXPECTED[@]}, $label has ${#other[@]}"
    echo "   Theme : ${SORTED_EXPECTED[*]}"
    echo "   $label: ${other[*]}"
    return 1
  fi
  local i
  for i in "${!SORTED_EXPECTED[@]}"; do
    if [[ "${SORTED_EXPECTED[$i]}" != "${other[$i]}" ]]; then
      echo "❌ Font list drift between Theme.bundledTypefaces and $label:"
      echo "   Theme : ${SORTED_EXPECTED[*]}"
      echo "   $label: ${other[*]}"
      return 1
    fi
  done
  return 0
}

# Every file the fetch script and the plist name must be a real LFW bundled file.
known_file() {
  local needle="$1" k
  for k in "${LFW_FILES[@]}"; do [[ "$k" == "$needle" ]] && return 0; done
  return 1
}

failed=0
# `${arr[@]+"${arr[@]}"}`: bash 3.2 (macOS) treats an empty array as unbound
# under `set -u`, which would crash the failure path instead of reporting it.
compare_lists "fetch_fonts.sh" ${FETCH_FONTS[@]+"${FETCH_FONTS[@]}"} || failed=1
compare_lists "RecipeToGroceryList/App/Info.plist" ${APP_FONTS[@]+"${APP_FONTS[@]}"} || failed=1
for f in ${FETCH_FONTS[@]+"${FETCH_FONTS[@]}"} ${APP_FONTS[@]+"${APP_FONTS[@]}"}; do
  if ! known_file "$f"; then
    echo "❌ $f is not one of LFWTypeface.bundledFileName's values (${LFW_FILES[*]})"
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "✅ Bundled typefaces in sync (${#SORTED_EXPECTED[@]} files): ${SORTED_EXPECTED[*]} — Theme.bundledTypefaces = [$(printf '.%s ' "${APP_CASES[@]}" | sed 's/ $//')]"
