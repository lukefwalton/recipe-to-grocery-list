# 002 — Ingredient identity: the seed and the one normalization (gate 1)

Gate 1 lays down schema v1 and the canonical ingredient registry. Two things had
to be decided before a single alias could be stored: what the seed *is* (and whose
it is), and what "the same name" means. Both were copied from `workout-logger`'s
exercise registry (`Storage/WorkoutStore+Exercises.swift`, `Storage/ExerciseSeed.swift`,
`Resources/seed_exercises.json` at `5bffddfb80fc`) and then tightened for food.

## Identity works exactly like exercise identity

`ingredients.id` is the immutable rowid every `recipe_ingredients` row points at;
`slug` is the stable seed/upsert key that never changes; `canonical_name` is the
display name the user may rename. Aliases live in their own table with **`alias`
as the PRIMARY KEY**, so an ambiguous term can never point at two canonicals — it
simply cannot be inserted twice, and the resolver falls through to "ask" instead
of resolving wrong (SPEC §3, §7.4). Seeding upserts on `slug`: an existing row keeps
its `canonical_name` and `is_custom`, only the seed-owned `category` is refreshed,
and aliases are `INSERT OR IGNORE`d so an alias the user already gave another
owner is left alone. Re-seeding on every launch is therefore idempotent, which is
what `RecipeStoreTests` pins (count unchanged on the second run, a renamed
canonical survives).

## The seed is ours, and it is built, not hand-edited

The word app's posture (`docs/prior-art-and-licensing.md`,
`docs/learnings/001-architecture.md` at `e829bcc9c0dc`): the cleanest way to avoid
a license question is to own the data. So `scripts/seed_source.json` is
hand-authored for this app and dedicated CC0 — 346 grocery items with categories
and 2,116 aliases, nothing scraped from a recipe site, a licensed dictionary or an
ingredient dataset. `scripts/build_seed.py` (modelled on the word app's
`build_corpus.py`) validates it and writes `Resources/seed_ingredients.json`;
CI runs `--check` and a `git status --porcelain` guard so the bundled file can
never drift from its source. The invariants it enforces are exactly the ones the
runtime would otherwise break silently:

- `slug == slugify(canonical_name)` — a custom the user creates in Confirm gets
  `IngredientNormalizer.slugify(name)`; if that item later ships in the seed it
  must land on the same upsert key, not duplicate it.
- canonical names unique under `normalize()`; aliases unique **globally** under
  `normalize()` (the PK, with `OR IGNORE`, would otherwise drop one silently);
- no alias normalize-equal to *any* canonical (the exact layer would shadow it);
- every category present, ≥ 250 items.

`SeedIngredientsTests` re-checks the same invariants at runtime with the Swift
normalizer, so the Python mirror and the Swift can never disagree unnoticed.

The seed deliberately contains the substring and modifier traps as *distinct*
canonicals — Cream / Heavy cream / Sour cream / Cream cheese / Ice cream, Chicken
/ Chicken broth, Paprika / Smoked paprika, Sugar / Brown sugar / Powdered sugar,
Tomato / Canned tomatoes / Tomato paste / Cherry tomato — because the resolver's
first defence against "chicken → chicken broth" is that the exact layer finds
"chicken" first. Canonicals are sentence case ("Vegetable broth") and singular for
countables ("Onion", "Egg"); plurals resolve through normalization, not aliases.

## One normalization, shared with the alias PRIMARY KEY

SPEC §7.1 defines it; `Model/Normalize.swift` is the only implementation and
`scripts/ingredient_normalize.py` mirrors it step for step (83 self-test cases).
In order: NFKC, strip diacritics, lowercase, drop parentheticals, collapse
whitespace, trim leading/trailing punctuation per token, drop a leading article
when something follows it, singularize the **last word only** (so "brussels
sprouts" → "brussels sprout", not "brussel sprout"). The singularization refines
the spec's one-line rule: words shorter than four letters, and words ending in
-us / -ss / -is, are never plurals in this vocabulary (hummus, molasses, couscous,
asparagus stay); `-ies` → `-y` (berries → berry); `-oes/-ches/-shes/-sses/-xes/-zes`
drop two letters (tomatoes → tomato, peaches → peach); otherwise one trailing s.
An explicit exception set covers mass nouns that end in s (grits, oats, greens).

The layer-1.5 **loose key** is the normalized form with every non-alphanumeric
removed, so "chick peas", "chickpeas" and "chick-peas" join. (`singularize`
originally skipped a hyphenated last word, so "chick-peas" was not singularized;
that landed in the Swift and the Python mirror together, with the seed rebuilt —
`f9e7a41`.)

Normalization is applied **exactly once** at insert and exactly once at lookup;
it is not guaranteed idempotent in theory (removing one article can expose
another), and nothing relies on it being so.

## What the schema itself guarantees

Every closed vocabulary is a `CHECK` in the DDL (category, source_kind,
resolution); `recipe_ingredients.ingredient_id` is `ON DELETE SET NULL` so a row
kept as text is representable and an ingredient deletion (v1.1) cannot orphan a
row; `check_state` and `ingredient_aliases` cascade with their ingredient. All of
it was exercised against the SPEC-verbatim DDL in `sqlite3` before the Swift was
written, and `SQLiteDBTests` pins it on device.
