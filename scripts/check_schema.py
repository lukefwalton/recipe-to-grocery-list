#!/usr/bin/env python3
"""Guard: the shipped SQLite schema is valid, matches the spec, and matches the enums.

Purpose:           Execute Schema.swift's v1 literal in real SQLite and check it against
                   SPEC §6 and the Swift enums whose raw values its CHECK constraints pin.
When to use:       CI (checks.yml) and before touching Storage/Schema.swift or SPEC §6.
Safe to run in prod?  Yes — reads two files, writes only an in-memory database.
Owner:             Luke F. Walton

Three drift risks this closes, none of which the Swift compiler can see:

  1. **The literal is a string.** `Schema.v1` is a Swift multiline string executed at
     first launch. A typo in it compiles perfectly and fails on a real device, on the
     one code path a user cannot retry. So the literal is executed here, in SQLite.
  2. **SPEC §6 duplicates it.** The spec's ```sql block and the Swift literal are the
     same schema written twice. Two copies drift; this compares the SQLite-normalized
     DDL of each, so comment and whitespace edits are free and a real difference is not.
  3. **The CHECK vocabularies duplicate the enums.** `category`, `source_kind` and
     `resolution` are closed vocabularies in both Swift (`IngredientCategory`,
     `SourceKind`, `RowResolution`) and SQL. Adding a case in Swift and forgetting the
     CHECK is a row the save path accepts and the database rejects — at write time.

Plus the structural invariants Schema.swift's own comments claim, asserted rather than
trusted: the alias PRIMARY KEY, the two different foreign-key delete actions, and
presence-based `check_state`.
"""

from __future__ import annotations

import os
import re
import sqlite3
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA_SWIFT = os.path.join(REPO, "RecipeToGroceryList", "Storage", "Schema.swift")
SPEC = os.path.join(REPO, "docs", "SPEC.md")
MODEL = os.path.join(REPO, "RecipeToGroceryList", "Model")

failures: list[str] = []


def fail(message: str) -> None:
    failures.append(message)


def read(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read()


# --------------------------------------------------------------------------- #
# Extraction
# --------------------------------------------------------------------------- #

def swift_v1_literal() -> str:
    """The body of `private static let v1 = \"\"\" … \"\"\"` in Schema.swift."""
    src = read(SCHEMA_SWIFT)
    match = re.search(r'static let v1 = """\n(.*?)\n\s*"""', src, re.S)
    if not match:
        sys.exit("::error::no `static let v1 = \"\"\"…\"\"\"` literal found in Schema.swift")
    body = match.group(1)
    # Swift strips the closing delimiter's indentation from every line. The closing
    # `"""` sits at four spaces, so four spaces come off each line.
    lines = []
    for line in body.split("\n"):
        if line.strip() and not line.startswith("    "):
            fail(f"v1 literal line is under-indented for its closing delimiter: {line!r}")
        lines.append(line[4:] if line.startswith("    ") else line)
    return "\n".join(lines)


def spec_sql_block() -> str:
    """The single ```sql block in SPEC.md (§6)."""
    blocks = re.findall(r"```sql\n(.*?)```", read(SPEC), re.S)
    if len(blocks) != 1:
        sys.exit(f"::error::expected exactly one ```sql block in SPEC.md, found {len(blocks)}")
    return blocks[0]


def swift_enum_cases(filename: str, enum: str) -> list[str]:
    """Raw values of a `String`-backed enum: every `case` declared at the top level
    of its body, whether the cases share one line or take one each. (Reading only
    the first `case` line would let a case added on its own line slip past the
    CHECK comparison — the exact mistake this guard exists to catch.)"""
    src = read(os.path.join(MODEL, filename))
    match = re.search(rf"enum {enum}: String[^{{]*\{{", src)
    if not match:
        sys.exit(f"::error::could not find `enum {enum}: String` in {filename}")
    index, depth = match.end(), 1
    while index < len(src) and depth:
        depth += (src[index] == "{") - (src[index] == "}")
        index += 1
    body = src[match.end():index - 1]
    cases: list[str] = []
    depth = 0
    for line in body.split("\n"):
        stripped = line.strip()
        # Only the enum's own cases: a `case .url:` inside a nested `switch` sits deeper.
        if depth == 0 and stripped.startswith("case "):
            cases.extend(case.strip() for case in stripped[len("case "):].split(","))
        depth += line.count("{") - line.count("}")
    if not cases:
        sys.exit(f"::error::could not read the cases of `{enum}` in {filename}")
    return cases


# --------------------------------------------------------------------------- #
# 1. It is valid SQL
# --------------------------------------------------------------------------- #

def apply(sql: str, label: str) -> sqlite3.Connection | None:
    db = sqlite3.connect(":memory:")
    db.execute("PRAGMA foreign_keys = ON")
    try:
        db.executescript(sql)
    except sqlite3.Error as error:
        fail(f"{label} is not valid SQLite: {error}")
        return None
    return db


def objects(db: sqlite3.Connection) -> dict[str, str]:
    """name → normalized DDL, for every table and index the script created."""
    rows = db.execute(
        "SELECT name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name"
    ).fetchall()
    out = {}
    for name, sql in rows:
        # Strip SQL comments and collapse whitespace: the two copies are allowed to
        # be commented and aligned differently, they are not allowed to differ.
        stripped = re.sub(r"--[^\n]*", " ", sql)
        out[name] = re.sub(r"\s+", " ", stripped).strip()
    return out


swift_sql = swift_v1_literal()
spec_sql = spec_sql_block()

swift_db = apply(swift_sql, "Schema.swift's v1 literal")
spec_db = apply(spec_sql, "the SPEC §6 ```sql block")

if swift_db is None or spec_db is None:
    print("FAILED — check_schema.py:\n  " + "\n  ".join(failures))
    raise SystemExit(1)

swift_objects = objects(swift_db)
spec_objects = objects(spec_db)

EXPECTED_TABLES = {
    "ingredients", "ingredient_aliases", "recipes",
    "recipe_ingredients", "check_state", "manual_items",
}

tables = {
    name for name in swift_objects
    if swift_objects[name].upper().startswith("CREATE TABLE")
}
if tables != EXPECTED_TABLES:
    fail(f"table set changed: {sorted(tables)} (expected {sorted(EXPECTED_TABLES)}) "
         "— update SchemaTests and this guard together if that is intended")

# --------------------------------------------------------------------------- #
# 2. The spec and the code agree (tables only; the indexes are an implementation
#    detail Schema.swift adds on top, which SPEC §6 says in prose).
# --------------------------------------------------------------------------- #

spec_tables = {n: d for n, d in spec_objects.items() if d.upper().startswith("CREATE TABLE")}
swift_tables = {n: d for n, d in swift_objects.items() if d.upper().startswith("CREATE TABLE")}

if set(spec_tables) != set(swift_tables):
    only_spec = sorted(set(spec_tables) - set(swift_tables))
    only_swift = sorted(set(swift_tables) - set(spec_tables))
    fail(f"SPEC §6 and Schema.swift define different tables — only in spec: {only_spec}; "
         f"only in Schema.swift: {only_swift}")
for name in sorted(set(spec_tables) & set(swift_tables)):
    if spec_tables[name] != swift_tables[name]:
        fail(f"table `{name}` differs between SPEC §6 and Schema.swift:\n"
             f"       spec: {spec_tables[name]}\n"
             f"      swift: {swift_tables[name]}")

# --------------------------------------------------------------------------- #
# 3. The CHECK vocabularies are exactly the Swift enums' raw values
# --------------------------------------------------------------------------- #

def check_vocabulary(table: str, column: str) -> list[str] | None:
    ddl = swift_tables.get(table)
    if ddl is None:
        return None
    match = re.search(rf"CHECK\s*\(\s*{column}\s+IN\s*\(([^)]*)\)", ddl, re.I)
    if not match:
        fail(f"`{table}.{column}` has no CHECK (… IN (…)) constraint — the database must "
             "reject a value the save path let through, not just the save path")
        return None
    return [value.strip().strip("'") for value in match.group(1).split(",")]


VOCABULARIES = [
    ("ingredients", "category", "IngredientCategory.swift", "IngredientCategory"),
    ("recipes", "source_kind", "RecipeDraft.swift", "SourceKind"),
    ("recipe_ingredients", "resolution", "RecipeDraft.swift", "RowResolution"),
]

for table, column, filename, enum in VOCABULARIES:
    sql_values = check_vocabulary(table, column)
    if sql_values is None:
        continue
    swift_values = swift_enum_cases(filename, enum)
    if sorted(sql_values) != sorted(swift_values):
        fail(f"`{table}.{column}` CHECK and `{enum}` disagree — "
             f"SQL only: {sorted(set(sql_values) - set(swift_values))}, "
             f"Swift only: {sorted(set(swift_values) - set(sql_values))}")

# --------------------------------------------------------------------------- #
# 4. The structural claims in Schema.swift's comments, asserted
# --------------------------------------------------------------------------- #

def columns(db: sqlite3.Connection, table: str) -> dict[str, sqlite3.Row]:
    db.row_factory = sqlite3.Row
    return {row["name"]: row for row in db.execute(f"PRAGMA table_info({table})")}


def foreign_keys(db: sqlite3.Connection, table: str) -> dict[str, sqlite3.Row]:
    db.row_factory = sqlite3.Row
    return {row["from"]: row for row in db.execute(f"PRAGMA foreign_key_list({table})")}


alias_columns = columns(swift_db, "ingredient_aliases")
if not alias_columns.get("alias") or alias_columns["alias"]["pk"] != 1:
    fail("`ingredient_aliases.alias` must be the PRIMARY KEY — one owner per term is what "
         "makes an ambiguous alias fall through to `ask` instead of resolving wrong (§7.4)")

recipe_ingredient_columns = columns(swift_db, "recipe_ingredients")
if recipe_ingredient_columns.get("ingredient_id") and recipe_ingredient_columns["ingredient_id"]["notnull"]:
    fail("`recipe_ingredients.ingredient_id` must be NULLABLE — a kept-as-text row has no "
         "ingredient, and a row whose ingredient is deleted becomes one (§1 'nothing dropped')")

recipe_ingredient_fks = foreign_keys(swift_db, "recipe_ingredients")
expected_actions = {"recipe_id": "CASCADE", "ingredient_id": "SET NULL"}
for column, action in expected_actions.items():
    row = recipe_ingredient_fks.get(column)
    if row is None:
        fail(f"`recipe_ingredients.{column}` has no foreign key")
    elif row["on_delete"] != action:
        fail(f"`recipe_ingredients.{column}` ON DELETE is {row['on_delete']}, expected {action} — "
             "deleting a recipe removes its rows, deleting an ingredient must not")

check_state_columns = columns(swift_db, "check_state")
if not check_state_columns.get("ingredient_id") or check_state_columns["ingredient_id"]["pk"] != 1:
    fail("`check_state.ingredient_id` must be the PRIMARY KEY — the table is presence-based "
         "and keyed by canonical ingredient, so a check survives list regeneration (§9)")
if len(check_state_columns) != 2:
    fail(f"`check_state` has {len(check_state_columns)} columns; presence-based means exactly "
         "ingredient_id + checked_at")

# --------------------------------------------------------------------------- #
# 5. Foreign keys actually bite (the pragma is set by SQLiteDB, not the schema)
# --------------------------------------------------------------------------- #

swift_db.execute("INSERT INTO ingredients (id, slug, canonical_name, category, created_at) "
                 "VALUES (1, 'salt', 'Salt', 'pantry', '2026-01-01T00:00:00Z')")
try:
    swift_db.execute("INSERT INTO ingredient_aliases (alias, ingredient_id) VALUES ('x', 999)")
except sqlite3.IntegrityError:
    pass
else:
    fail("a foreign key to a missing ingredient was accepted — REFERENCES is declared but not "
         "enforced (the app sets `PRAGMA foreign_keys = ON` in SQLiteDB)")

try:
    swift_db.execute("INSERT INTO ingredients (id, slug, canonical_name, category, created_at) "
                     "VALUES (2, 'pepper', 'Pepper', 'condiments', '2026-01-01T00:00:00Z')")
except sqlite3.IntegrityError:
    pass
else:
    fail("a category outside the closed vocabulary was accepted — the CHECK constraint is not biting")

# --------------------------------------------------------------------------- #

if failures:
    print("FAILED — check_schema.py:")
    for failure in failures:
        print(f"  ::error::{failure}")
    raise SystemExit(1)

print(f"✅ Schema v1 OK — {len(swift_tables)} tables, "
      f"{len(swift_objects) - len(swift_tables)} indexes; executes in SQLite, "
      f"matches SPEC §6, CHECK vocabularies match IngredientCategory/SourceKind/RowResolution")
