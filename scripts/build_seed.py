#!/usr/bin/env python3
"""Build the bundled ingredient library (seed_ingredients.json) from its source of record.

Purpose:           Validate scripts/seed_source.json and (re)generate
                   RecipeToGroceryList/Resources/seed_ingredients.json.
When to use:       After editing the seed source (add, remove, re-categorize or
                   re-alias an ingredient). CI runs `--check` to prove the bundled
                   file is byte-identical to what the source would produce.
Safe to run in prod?  Yes — deterministic; only rewrites the generated output.
Owner:             Luke F. Walton

Modelled on a-new-word-every-day/scripts/build_corpus.py (@e829bcc9c0dc): bundled
data is built, not hand-edited, and the build fails loudly on every invariant the
runtime would otherwise break silently (spec §3 "Bundled data is built, not
hand-edited", §6 seed rules).

The seed is original work: every canonical name and alias in seed_source.json was
written for this app and is dedicated to the public domain (CC0). Nothing was
scraped or copied from a recipe site, dictionary or dataset; see
docs/prior-art-and-licensing.md and keep the in-app Acknowledgements in sync.

Why each invariant exists (all checked with scripts/ingredient_normalize.py, the
step-for-step mirror of IngredientNormalizer; SeedIngredientsTests re-checks them at
runtime with the Swift code so drift between the two fails a test):

  * slug == slugify(canonical_name) — a custom ingredient created in Confirm gets
    IngredientNormalizer.slugify(name); a seed entry that later ships for the same
    name must land on the same upsert key instead of duplicating it.
  * canonical names unique under normalize() — layer 0 matches canonicals
    case-insensitively and the alias key is the normalized form, so "Tomato" and
    "tomatoes" would resolve nondeterministically.
  * aliases globally unique under normalize() — `ingredient_aliases.alias` is the
    PRIMARY KEY and the seed inserts with OR IGNORE, so a second owner is silently
    dropped at seed time.
  * no alias normalize-equal to ANY canonical — resolution is exact → alias, so
    such an alias is shadowed by the exact layer (and, for its own canonical, is
    just redundant: "tomatoes" already normalizes to "tomato").
  * every category represented and ≥ MIN_ITEMS entries — the list screen groups
    by category (§9) and the spec promises "a few hundred common items".

Usage:
    python3 scripts/build_seed.py            # validate + write
    python3 scripts/build_seed.py --check    # validate + verify the bundled file is current (CI)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

# Import the normalizer mirror from this directory regardless of the cwd. Bytecode
# is switched off first so running the build never litters scripts/__pycache__/
# into the repo (the only Python here is these two files; caching buys nothing).
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from ingredient_normalize import normalize, slugify  # noqa: E402

# Shown in Settings as "Seed version". Kept in sync BY HAND with
# `IngredientSeed.version` in RecipeToGroceryList/Storage/IngredientSeed.swift;
# `--check` (and every build) fails if the two disagree. Bump both when the seed
# content changes in a way worth telling the user about.
SEED_VERSION = "2026.09"

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = Path(__file__).resolve().with_name("seed_source.json")
DEFAULT_OUT = REPO_ROOT / "RecipeToGroceryList" / "Resources" / "seed_ingredients.json"
SWIFT_SEED = REPO_ROOT / "RecipeToGroceryList" / "Storage" / "IngredientSeed.swift"

# The closed vocabulary — identical to `IngredientCategory` and the schema's
# CHECK (category IN (…)) in spec §6. A category outside this set would fail the
# Codable decode at launch, i.e. an app that cannot seed.
CATEGORIES = ("produce", "dairy", "meat", "seafood", "bakery", "pantry", "frozen", "other")

# Exactly the keys `SeedIngredient` decodes (snake_case, like seed_exercises.json).
KEYS = ("slug", "canonical_name", "category", "aliases")

# Slugs are the import/export key and appear in test fixtures, so keep them boring.
SLUG_RE = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*$")

# Spec §6: "a few hundred common items". Below this the library is too thin for the
# deterministic layers to carry a typical recipe, and more rows land in "New".
MIN_ITEMS = 250


def load_source(source: Path) -> list:
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as exc:
        raise SystemExit(f"FAILED — cannot read {source}: {exc}")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"FAILED — {source.name} is not valid JSON: {exc}")


def validate(rows: object, source_name: str) -> list[dict]:
    """Returns the rows if every invariant holds; otherwise exits listing EVERY
    error, so one build fixes a whole editing session rather than one typo."""
    if not isinstance(rows, list) or not all(isinstance(r, dict) for r in rows):
        raise SystemExit(f"FAILED — {source_name} must be a JSON array of objects")

    errors: list[str] = []

    # Pass 1: per-item shape and typing. Type-strict so a hand-edit typo (e.g.
    # "aliases": "garbanzo") fails here rather than at launch inside Codable.
    for i, r in enumerate(rows):
        tag = r.get("slug") or r.get("canonical_name") or f"#{i}"
        keys = tuple(r.keys())
        if set(keys) != set(KEYS):
            extra = sorted(set(keys) - set(KEYS))
            missing = sorted(set(KEYS) - set(keys))
            errors.append(f"{tag}: keys must be exactly {list(KEYS)}"
                          + (f"; unexpected {extra}" if extra else "")
                          + (f"; missing {missing}" if missing else ""))
        name = r.get("canonical_name")
        if not isinstance(name, str) or not name.strip():
            errors.append(f"{tag}: canonical_name must be a non-empty string")
        elif name != " ".join(name.split()):
            errors.append(f"{tag}: canonical_name {name!r} has stray whitespace (trim, single spaces)")
        elif not normalize(name):
            errors.append(f"{tag}: canonical_name {name!r} normalizes to nothing")
        slug = r.get("slug")
        if not isinstance(slug, str) or not SLUG_RE.match(slug):
            errors.append(f"{tag}: slug {slug!r} must match {SLUG_RE.pattern}")
        elif isinstance(name, str) and slug != slugify(name):
            errors.append(f"{tag}: slug {slug!r} must equal slugify(canonical_name) = {slugify(name)!r}")
        if r.get("category") not in CATEGORIES:
            errors.append(f"{tag}: category {r.get('category')!r} must be one of {list(CATEGORIES)}")
        aliases = r.get("aliases")
        if not isinstance(aliases, list):
            errors.append(f"{tag}: aliases must be a JSON array of strings")
        else:
            for alias in aliases:
                if not isinstance(alias, str) or not alias.strip():
                    errors.append(f"{tag}: alias {alias!r} must be a non-empty string")
                elif alias != " ".join(alias.split()):
                    errors.append(f"{tag}: alias {alias!r} has stray whitespace (trim, single spaces)")
                elif not normalize(alias):
                    errors.append(f"{tag}: alias {alias!r} normalizes to nothing")

    # Pass 2: cross-item invariants. Each check runs on every row that has the
    # fields *it* needs, so one malformed field never hides a different error
    # elsewhere on the same row (the whole point of reporting everything at once).
    named = [r for r in rows if isinstance(r.get("slug"), str) and isinstance(r.get("canonical_name"), str)]
    well_formed = [r for r in named if isinstance(r.get("aliases"), list)]

    slug_owners: dict[str, list[str]] = defaultdict(list)
    for r in named:
        slug_owners[r["slug"]].append(r["canonical_name"])
    for slug, names in sorted(slug_owners.items()):
        if len(names) > 1:
            errors.append(f"duplicate slug {slug!r}: {names}")

    canonical_by_key: dict[str, list[str]] = defaultdict(list)
    for r in named:
        canonical_by_key[normalize(r["canonical_name"])].append(r["canonical_name"])
    for key, names in sorted(canonical_by_key.items()):
        if len(names) > 1:
            errors.append(f"canonical names collide under normalize ({key!r}): {names}")
    canonical_key_to_slug = {normalize(r["canonical_name"]): r["slug"] for r in named}

    alias_owners: dict[str, list[tuple[str, str]]] = defaultdict(list)   # key → [(alias, slug)]
    for r in well_formed:
        own_key = normalize(r["canonical_name"])
        for alias in r["aliases"]:
            if not isinstance(alias, str):
                continue
            key = normalize(alias)
            if not key:
                continue
            alias_owners[key].append((alias, r["slug"]))
            if key == own_key:
                errors.append(f"{r['slug']}: alias {alias!r} is redundant — it normalizes to its own "
                              f"canonical name ({key!r}); the exact layer already catches it")
            elif key in canonical_key_to_slug:
                errors.append(f"{r['slug']}: alias {alias!r} equals {canonical_key_to_slug[key]}'s canonical "
                              f"name under normalize ({key!r}) — it would be shadowed by the exact layer")
    for key, owners in sorted(alias_owners.items()):
        if len(owners) > 1:
            listed = ", ".join(f"{alias!r} on {slug}" for alias, slug in owners)
            errors.append(f"alias {key!r} has more than one owner: {listed}")

    # Pass 3: library-level requirements.
    if len(rows) < MIN_ITEMS:
        errors.append(f"the seed needs at least {MIN_ITEMS} items (spec §6 'a few hundred'); found {len(rows)}")
    present = {r.get("category") for r in rows}
    missing_categories = [c for c in CATEGORIES if c not in present]
    if missing_categories:
        errors.append(f"every category must be represented; missing {missing_categories}")

    # The Settings screen shows IngredientSeed.version; keep it honest.
    if SWIFT_SEED.exists():
        match = re.search(r'static\s+let\s+version\s*=\s*"([^"]*)"', SWIFT_SEED.read_text(encoding="utf-8"))
        if match is None:
            errors.append(f"could not find `static let version = \"…\"` in {SWIFT_SEED.relative_to(REPO_ROOT)}; "
                          "the version check would otherwise be silently skipped")
        elif match.group(1) != SEED_VERSION:
            errors.append(f"SEED_VERSION {SEED_VERSION!r} != IngredientSeed.version {match.group(1)!r} "
                          f"in {SWIFT_SEED.relative_to(REPO_ROOT)}; bump both together")

    if errors:
        raise SystemExit(f"FAILED — fix {source_name} ({len(errors)} error(s)):\n" + "\n".join(errors))
    return rows


def render(rows: list[dict]) -> str:
    """The exact bytes of the bundled file: sorted by slug (a stable diff when the
    source is reordered), fixed key order, indent 2, real UTF-8, trailing newline."""
    out_rows = [
        {"slug": r["slug"], "canonical_name": r["canonical_name"],
         "category": r["category"], "aliases": list(r["aliases"])}
        for r in sorted(rows, key=lambda r: r["slug"])
    ]
    return json.dumps(out_rows, indent=2, ensure_ascii=False) + "\n"


def report(rows: list[dict]) -> None:
    by_category = Counter(r["category"] for r in rows)
    alias_count = sum(len(r["aliases"]) for r in rows)
    print(f"Seed version {SEED_VERSION}: {len(rows)} ingredients, {alias_count} aliases")
    print("Categories:", {c: by_category.get(c, 0) for c in CATEGORIES})


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--check", action="store_true",
                    help="validate, then exit 1 unless --out is byte-identical to what would be written")
    args = ap.parse_args()

    rows = validate(load_source(args.source), args.source.name)
    rendered = render(rows)

    if args.check:
        try:
            current = args.out.read_text(encoding="utf-8")
        except OSError:
            raise SystemExit(f"FAILED — {args.out} is missing; run scripts/build_seed.sh and commit the result")
        if current != rendered:
            raise SystemExit(f"FAILED — {args.out.relative_to(REPO_ROOT) if args.out.is_relative_to(REPO_ROOT) else args.out} "
                             f"is out of date with {args.source.name}; run scripts/build_seed.sh and commit the result")
        report(rows)
        print(f"OK — {args.out.name} matches {args.source.name}")
        return

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(rendered, encoding="utf-8")
    report(rows)
    print(f"Wrote {len(rows)} ingredients to {args.out}")


if __name__ == "__main__":
    main()
