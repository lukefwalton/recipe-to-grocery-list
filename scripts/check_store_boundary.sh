#!/usr/bin/env bash
#
# ============================================
# Purpose:           Guard the store's write-path boundary and the Share Extension's no-database rule.
# When to use:       In CI on every PR (checks.yml), and locally before pushing storage or extension changes.
# Safe to run in prod?  Yes — read-only validation, makes no writes.
# Owner:             Luke F. Walton
# ============================================
#
# Adapted from workout-logger@5bffddfb80fc scripts/check_store_boundary.sh.
#
# RecipeStore spans several files (RecipeStore+Ingredients / +Recipes / +List),
# which forces a handful of members to `internal` (Swift's `private` is
# file-scoped): the raw connection (`db`) and the writers the save transaction
# shares across files (`insertIngredientRow`, `insertAliasRow`, `uniqueSlug`,
# `gcCheckState`). The compiler no longer stops feature code from calling them
# and bypassing `RecipeStore.save` — so this check does.
#
# The guarded surface below is the COMPLETE write-capable set: the other
# cross-file internal members (`count(inTable:)`, `snapshot`, `ingredientID(slug:)`,
# `aliasOwner`, the ISO/date/JSON statics) are read-only BY CONSTRUCTION —
# `count(inTable:)` takes a validated bare identifier and builds its SELECT
# internally, so it cannot serve as an ad hoc SQL entry point. If a future split
# widens another helper that accepts SQL text or can write, add it to
# WRITE_SURFACE in the same change, with a self-test fixture.
#
# Rules, over production sources only (tests use @testable deliberately):
#   1. Outside RecipeToGroceryList/Storage/, no reference to the store-internal
#      write helpers or to a store's raw `.db` connection.
#   2. Outside Storage/, nobody constructs a SQLiteDB. Unlike the workout app
#      there is no Shared allowance: there is no widget, and the Share
#      Extension never opens the database (SPEC §3 "Deliberately different").
#   3. Nothing compiled into the Share Extension touches the database at all:
#      files under RecipeShareExtension/ may not even mention RecipeStore,
#      SQLiteDB or `import SQLite3`, and the Shared module (compiled into the
#      extension too) may not `import SQLite3`. RecipeStore/SQLiteDB references
#      in Shared would already fail to compile for the extension target, so
#      only the import — which would compile — needs a textual guard there.
#
# The script SELF-TESTS on every run before checking the real tree: it builds
# sandbox fixtures (clean, each violation class, the Storage allowance) and
# asserts the rules catch/pass them. A regex edit that silently weakens the
# guard therefore fails CI by itself, with no violation needed in the repo.
#
# Exits non-zero with the offending lines when the boundary is crossed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# `\.db\b` catches any `<store>.db` access regardless of the variable name;
# the write helpers are matched as whole words so both calls and bare method
# references (`let f = store.insertAliasRow`) trip the guard.
WRITE_SURFACE='\binsertIngredientRow\b|\binsertAliasRow\b|\bgcCheckState\b|\buniqueSlug\b|\.db\b'
# The extension must not even name the store or the connection type.
EXTENSION_FORBIDDEN='\bRecipeStore\b|\bSQLiteDB\b|import[[:space:]]+SQLite3\b'
SHARED_FORBIDDEN='import[[:space:]]+SQLite3\b'

# Check one tree. Prints violations; returns 0 clean, 1 violated, 2 unusable.
check_tree() {
  local tree="$1"
  local status=0
  local sources=()
  while IFS= read -r f; do sources+=("$f"); done < <(
    cd "$tree" && find RecipeToGroceryList RecipeShareExtension -name '*.swift' \
      -not -path 'RecipeToGroceryList/Storage/*' 2>/dev/null | sort)
  if [[ ${#sources[@]} -eq 0 ]]; then
    echo "❌ No production Swift sources found under $tree — cannot check the boundary"
    return 2
  fi

  local hits
  if hits=$( (cd "$tree" && grep -nE "$WRITE_SURFACE" "${sources[@]}") 2>/dev/null ); then
    echo "❌ Store-internal write surface referenced outside RecipeToGroceryList/Storage/:"
    echo "$hits" | sed 's/^/   /'
    echo "   Every recipe write must go through the typed store API (RecipeStore.save / setSelected / …)."
    status=1
  fi

  if hits=$( (cd "$tree" && grep -nE 'SQLiteDB\(' "${sources[@]}") 2>/dev/null ); then
    echo "❌ SQLiteDB constructed outside RecipeToGroceryList/Storage/:"
    echo "$hits" | sed 's/^/   /'
    echo "   Feature code gets its connection through RecipeStore (AppDatabase.makeStore), never directly."
    status=1
  fi

  local ext_sources=()
  while IFS= read -r f; do ext_sources+=("$f"); done < <(
    cd "$tree" && find RecipeShareExtension -name '*.swift' 2>/dev/null | sort)
  if [[ ${#ext_sources[@]} -gt 0 ]]; then
    if hits=$( (cd "$tree" && grep -nE "$EXTENSION_FORBIDDEN" "${ext_sources[@]}") 2>/dev/null ); then
      echo "❌ The Share Extension mentions the database layer (it must never open the store):"
      echo "$hits" | sed 's/^/   /'
      echo "   The extension only appends to the App Group inbox (Shared/ShareInbox.swift)."
      status=1
    fi
  fi

  local shared_sources=()
  while IFS= read -r f; do shared_sources+=("$f"); done < <(
    cd "$tree" && find RecipeToGroceryList/Shared -name '*.swift' 2>/dev/null | sort)
  if [[ ${#shared_sources[@]} -gt 0 ]]; then
    if hits=$( (cd "$tree" && grep -nE "$SHARED_FORBIDDEN" "${shared_sources[@]}") 2>/dev/null ); then
      echo "❌ The Shared module imports SQLite3 (it is compiled into the Share Extension):"
      echo "$hits" | sed 's/^/   /'
      status=1
    fi
  fi

  return $status
}

# Build a minimal fixture tree: one clean file per dir, plus an optional
# planted file at $2 with content $3.
make_fixture() {
  local sandbox="$1" plant_path="${2:-}" plant_content="${3:-}"
  mkdir -p "$sandbox/RecipeToGroceryList/Features" "$sandbox/RecipeToGroceryList/Shared" \
           "$sandbox/RecipeToGroceryList/Storage" "$sandbox/RecipeShareExtension"
  echo 'let id = try store.save(draft)' > "$sandbox/RecipeToGroceryList/Features/Clean.swift"
  echo 'enum AppGroup { static let identifier = "group.example" }' > "$sandbox/RecipeToGroceryList/Shared/Clean.swift"
  echo 'final class ShareViewController: UIViewController {}' > "$sandbox/RecipeShareExtension/Clean.swift"
  # Storage may (and does) use the raw surface — must never trip the check.
  echo 'let x = try db.transaction { try insertIngredientRow(slug: s); try gcCheckState() }' \
    > "$sandbox/RecipeToGroceryList/Storage/Store.swift"
  echo 'let db = try SQLiteDB(path: url.path)' > "$sandbox/RecipeToGroceryList/Storage/AppDatabase.swift"
  if [[ -n "$plant_path" ]]; then
    mkdir -p "$sandbox/$(dirname "$plant_path")"
    echo "$plant_content" > "$sandbox/$plant_path"
  fi
}

# One self-test case: expect check_tree on the fixture to exit with $1.
expect() {
  local want="$1" label="$2" plant_path="${3:-}" plant_content="${4:-}"
  local sandbox
  sandbox="$(mktemp -d)"
  make_fixture "$sandbox" "$plant_path" "$plant_content"
  local got=0
  check_tree "$sandbox" > /dev/null 2>&1 || got=$?
  rm -rf "$sandbox"
  if [[ "$got" -ne "$want" ]]; then
    echo "❌ Guard self-test failed: $label (expected exit $want, got $got)"
    echo "   The check itself has regressed — fix the script before trusting a green run."
    exit 1
  fi
}

self_test() {
  expect 0 "clean tree passes"
  expect 1 "raw connection access is caught" \
    "RecipeToGroceryList/Features/Bad.swift" 'let x = store.db'
  expect 1 "insertIngredientRow call is caught" \
    "RecipeToGroceryList/Features/Bad.swift" 'let id = try store.insertIngredientRow(slug: s, canonicalName: n, category: .other, isCustom: true)'
  expect 1 "insertAliasRow call is caught" \
    "RecipeToGroceryList/Features/Bad.swift" 'try store.insertAliasRow(a, ingredientID: id, isCustom: true, ignoringConflicts: false)'
  expect 1 "gcCheckState call is caught" \
    "RecipeToGroceryList/Features/Bad.swift" 'try store.gcCheckState()'
  expect 1 "uniqueSlug call is caught" \
    "RecipeToGroceryList/Features/Bad.swift" 'let slug = try store.uniqueSlug(forName: name)'
  expect 1 "bare method reference (no call parens) is caught" \
    "RecipeToGroceryList/Features/Bad.swift" 'let f = store.insertAliasRow'
  expect 1 "SQLiteDB construction in Features is caught" \
    "RecipeToGroceryList/Features/Bad.swift" 'let db = try SQLiteDB(path: p)'
  expect 1 "SQLiteDB construction in Shared is caught (no widget, no allowance)" \
    "RecipeToGroceryList/Shared/Bad.swift" 'let db = try SQLiteDB(path: p)'
  expect 1 "SQLiteDB construction in the extension is caught" \
    "RecipeShareExtension/Bad.swift" 'let db = try SQLiteDB(path: p)'
  expect 1 "extension naming RecipeStore is caught" \
    "RecipeShareExtension/Bad.swift" '// TODO: read RecipeStore here'
  expect 1 "extension importing SQLite3 is caught" \
    "RecipeShareExtension/Bad.swift" 'import SQLite3'
  expect 1 "Shared importing SQLite3 is caught (compiled into the extension)" \
    "RecipeToGroceryList/Shared/Bad.swift" 'import SQLite3'
  expect 0 "a second Storage file may construct SQLiteDB and use the raw surface" \
    "RecipeToGroceryList/Storage/More.swift" 'let other = try SQLiteDB(path: p); _ = other.db; try uniqueSlug(forName: n)'
  expect 0 "unrelated .database / dbx identifiers do not false-positive" \
    "RecipeToGroceryList/Features/Fine.swift" 'let a = model.database; let b = store.dbx; let c = slug.uniqueSlugged'
  echo "✅ Guard self-test passed (15 fixtures)"
}

self_test

if ! check_tree "$ROOT"; then
  exit 1
fi

echo "✅ Store write-path boundary intact: raw connection + store writers only referenced under RecipeToGroceryList/Storage/; the Share Extension never names the database"
