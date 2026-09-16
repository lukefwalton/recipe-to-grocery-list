# Recipe to Grocery List — Spec

A local-first iOS app that turns recipes into one grocery list. Capture a
recipe (URL, pasted text, or photo), confirm the parsed ingredient rows, pick
any set of saved recipes, and get a single merged list you can check off in
the store. No login, no payment inside the app, nothing leaves the phone except
the one page fetch you explicitly hand it.

This document is the design for v1. v1 is implemented on this branch, gate by
gate per the [PR gates](#12-pr-gates) table — see
[Status & scope](#status--scope) for what remains. Sibling apps:
[Private Workout Logger](https://github.com/lukefwalton/workout-logger)
(`workout-logger`) and
[A New Word Every Day](https://github.com/lukefwalton/a-new-word-every-day)
(`a-new-word-every-day`). Where this spec says "inherit", it means copy the
pattern from those repos rather than re-derive it.

Working name: **Recipe to Grocery List** (matches the repo). Final App Store
name is open (§13).

---

## 1. Product at a glance

- **Capture** a recipe three ways: share/paste a URL, paste text, or photograph
  a page. Every path converges on the same thing: an array of raw ingredient
  lines. One pipeline after that.
- **Confirm** the parse. The app proposes structured rows (quantity, unit, name,
  note) resolved to a canonical ingredient; the user fixes what's wrong and
  taps Save. Nothing is written until they do.
- **Select** any saved recipes as "cooking this".
- **Shop** from one merged list, grouped by canonical ingredient, checkable, with
  the odd manual item ("also coffee") mixed in. Check state survives adding or
  removing recipes.

### Principles

| Principle | What it means here |
|---|---|
| Local-first | On-device SQLite is the sole source of truth. No sync, no server. |
| One write path | `RecipeDraft → validate → transaction → save`. Views never touch the DB. |
| Model proposes, app confirms, app writes | The LLM (and every fuzzy layer) suggests; the user confirms; the store writes. The model never holds write authority. |
| Nothing silently dropped | Every raw line the user gave us is visible in the confirm UI and kept in the DB. Canonicalization is additive. |
| Honest numbers | Quantities are never converted or summed across differing units. A wrong sum is worse than no sum. |
| Usable without AI | Every feature works on a device without Apple Intelligence. The LLM makes it less chatty, not possible. |

### Confirmed product decisions

| Decision | Choice |
|---|---|
| Platform | iOS only, iPhone only (`TARGETED_DEVICE_FAMILY "1"`), same as siblings |
| Deployment target | iOS 17.0, matching the family; Foundation Models gated behind `#if canImport(FoundationModels)` + `#available(iOS 26.0, *)` + runtime availability, exactly as `workout-logger` does |
| Account / cloud / analytics | None. Zero. |
| LLM | On-device Foundation Models only. No cloud LLM of any kind, not even as an opt-in. |
| Photo capture | Still photo + `VNRecognizeTextRequest` (whole page beats live scanning for cookbook layouts) |
| Clarification loop | **Not inherited.** The confirm UI *is* the clarification step for ingredient rows (§7.5) |
| Units | No conversion. Sum only when unit keys match after normalization (§8) |
| Look | `lfwdesignsystem` as-is: Forest palette default, Fraunces for display, Inter for chrome, user theme picker via `LFWThemeConfig` (§4.2) |
| Price | Open — see §13. Do not put "Free" or a price in the app name, subtitle, or promo text (App Store Guideline 2.3.7; the word app was rejected for this once) |

---

## 2. Non-goals for v1

Explicitly out, so nobody designs a seam for them by accident:

- Meal planning, calendar, weekly view
- Nutrition, calories, macros
- Pantry / "what I already have" inventory
- Recipe scaling and servings math (we store `servings_text` raw, nothing more)
- Unit conversion (§8)
- Sharing, sync, iCloud, family lists
- Cook mode, step-by-step instructions UI (we do not store instructions at all)
- Multiple lists or named shopping trips (there is one list)
- Home Screen widget, Live Activity, Watch
- Import from other recipe apps (Paprika, AnyList, etc.)
- Localization beyond English (ingredient seed, unit table, and prompts are English-only)
- Export to Reminders (`EventKit`) — flagged as a v1.1 candidate in §9

---

## 3. Inheritance from the family

### Inherit as-is (copy the pattern, cite the source file in the PR)

Storage, identity, resolution, and the FM adapter come from `workout-logger`.
Look, feel, theming, fonts, release scripts, and the data-licensing posture come
from `a-new-word-every-day`, which is the most polished of the family and the
canonical home of the design system.

Every citation below was checked against a specific revision and refers to that
revision, not to whatever the sibling repos contain later:

| Repo | Revision | Date |
|---|---|---|
| `lukefwalton/workout-logger` | `5bffddfb80fc` | 2026-07-11 |
| `lukefwalton/a-new-word-every-day` | `e829bcc9c0dc` (`lfwdesignsystem` 2.3.0) | 2026-09-01 |

When a gate copies a pattern, cite the file at the revision you copied from; if it
has moved on, re-read it and update this table in the same PR.

| Pattern | Source | Notes |
|---|---|---|
| Raw `sqlite3` C API, no ORM; WAL, `foreign_keys = ON`, whole-closure lock around `transaction` / `readTransaction`, read-only enforcement via `sqlite3_stmt_readonly` | `Storage/SQLiteDB.swift` | Rationale in `docs/learnings/001-spine.md`: zero dependencies, app-owned SQL |
| Store type `@unchecked Sendable`; **write methods** are `@MainActor`, reads are non-isolated; `snapshot(_:)` for multi-read consistency | `Storage/WorkoutStore.swift` | Note: `@MainActor` is on the mutating methods, not the type |
| Composition root `makeStore()` → open → `migrate()` → `seedIngredientsIfNeeded()` | `Storage/AppDatabase.swift` | |
| Forward-only migrations on `PRAGMA user_version`; fresh install lays down all versions in one transaction; CHECK constraints on closed vocabularies | `Storage/Schema.swift` | |
| Single write path `Draft → validate → transaction → save`; validator is a plain `enum` that throws | `Storage/WorkoutValidator.swift`, `WorkoutStore+Sessions.swift` | |
| Store-boundary CI guard: nothing outside `Storage/` touches the raw `db` | `scripts/check_store_boundary.sh` | |
| Canonical identity: `id INTEGER PK` + `slug TEXT UNIQUE` + `canonical_name`; alias table with **`alias` as PRIMARY KEY** so an ambiguous term cannot map to two canonicals and falls through to "ask" | `Storage/Schema.swift` (`exercises`, `exercise_aliases`) | Ingredient identity works exactly like exercise identity |
| Seed loader: bundled JSON, snake_case keys, `load(from bundle:)` so tests seed from their own bundle; upsert on `slug`, `INSERT OR IGNORE` aliases, never overwrite a user-renamed `canonical_name` | `Storage/ExerciseSeed.swift`, `WorkoutStore+Exercises.swift`, `Resources/seed_exercises.json` | |
| Seed invariant tests: unique slugs, unique canonical names, aliases unique *after normalization*, no alias equal to another item's canonical name | `WorkoutChatLogTests/SeedExercisesTests.swift` | |
| Resolution layers: exact → alias → loose key → fuzzy (Jaro-Winkler / token average, 0.78) → contextual embeddings (0.85 escalation, `NLContextualEmbedding`, additive never displacing) → LLM | `WorkoutStore+Exercises.swift`, `Model/FuzzyMatch.swift`, `Model/SemanticSuggester.swift`, `docs/learnings/010-fuzzy-resolution.md` | Thresholds are starting points; recalibrate against the ingredient golden corpus (§11) |
| Foundation Models adapter shape: FM file entirely inside `#if canImport(FoundationModels)`; FM-free mapping layer that is always compiled and unit-tested; factory wires FM only when SDK + OS + runtime availability all agree; `foundation-models-guard` CI job on `macos-26` | `Parsing/FoundationWorkoutParser.swift`, `Parsing/ModelDraftMapping.swift`, `Parsing/WorkoutParserOrchestrator.swift`, `.github/workflows/ios-tests.yml` | |
| `@Generable` response types with `@Guide` descriptions; outcome enum `draft \| declined` with a typed decline reason | `Parsing/FoundationWorkoutParser.swift`, `Model/ParseOutcome.swift` | Clarification case dropped, see below |
| XcodeGen `project.yml` + `project.local.yml` (gitignored `DEVELOPMENT_TEAM`), `scripts/generate.sh`, `scripts/run_tests.sh` | `project.yml`, `scripts/` | |
| Vendored `lfwdesignsystem/` (2.3.0 today), pulled in with `scripts/sync_designsystem.sh` *from* the word repo, guarded by `check_designsystem_sync.sh` + `CHECKSUMS.txt`; app-side `Theme` enum forwarding to `LFWColors` | `a-new-word-every-day/lfwdesignsystem/`, `workout-logger/App/Theme.swift` | Edit the design system in the word repo only, then sync |
| User theming: `LFWThemeConfig` (typeface + `LFWPalette` + accent nudge), `LFWThemedBackground`, `LFWTypography.font(_:typeface:)` with `LFWTextRole`, system-font fallback when OFL fonts aren't bundled | `a-new-word-every-day/docs/SPEC.md` §4, `docs/learnings/001-architecture.md` | Forest is the default palette, per the style guide |
| OFL variable fonts fetched, not committed: `scripts/fetch_fonts.sh`, `scripts/check_fonts_sync.sh`, `OFL.txt` + in-app Acknowledgements | `a-new-word-every-day/scripts/` | Only Fraunces and Inter are needed here; trim the fetch list |
| Family components: `LFWOnboardingScaffold` + `LFWPageDots`, `LFWCard`, `LFWEmptyState`, `LFWCTAButtonStyle`, `LFWHaptics`, on-palette status colors (`success` / `warning` / `danger`, never system `.red`) | `lfwdesignsystem/Sources/LFWDesignSystem/`, `STYLE-GUIDE.md` | |
| Release tooling: `scripts/release.sh` (fonts + tests + archive), `scripts/setup_signing.sh`, `ITSAppUsesNonExemptEncryption: false`, `docs/app-store-metadata.md` with the Guideline 2.3.7 note | `a-new-word-every-day/scripts/`, `docs/app-store-metadata.md` | |
| Bundled data is built, not hand-edited: a `scripts/*_source.json` source of record + a validating build script that assigns stable ids and fails on duplicates | `a-new-word-every-day/scripts/build_corpus.py` | Applied to the ingredient seed (§6) |
| Permissive-only data posture, written down in `docs/prior-art-and-licensing.md`: own the data when a license question would otherwise exist | `a-new-word-every-day/docs/prior-art-and-licensing.md` | The seed list is hand-authored and CC0 for exactly this reason |
| Port, don't depend: zero runtime dependencies; a small algorithm is re-implemented with attribution rather than vendored as a package | `a-new-word-every-day/docs/learnings/002-fsrs-review.md` | Applies to Jaro-Winkler, fraction parsing, JSON-LD walking |
| Keep mutable non-DB state tiny and injectable (`SharedStore` takes a `UserDefaults`; tests use a throwaway suite) | `a-new-word-every-day/Shared/SharedStore.swift` | Here: theme config, onboarding flag, Share Extension inbox |
| `NOTICE.md` copy rule and reuse log format (Source / Retrieved / License / What was used / Copied verbatim? / Notice required? / Used as) | `NOTICE.md` | |
| `docs/privacy.md`, `docs/learnings/NNN-slug.md`, `.github/STANDARDS.md`, PR template with the doctrine checklist | `docs/`, `.github/` | |

### Deliberately different

| Departure | Why |
|---|---|
| **No session lifecycle.** No "open session", no single-open invariant, no partial-unique index. | Recipes are documents, not time-boxed events. |
| **Per-row results, not all-or-nothing.** `workout-logger`'s `ModelDraftMapping.result` declines the whole entry if any set is unreadable (`compactMap` count check). Here a bad row must become a visible *unresolved* row, never a reason to discard the other fourteen. | A recipe has 5–30 lines; one weird line ("a splash of something") must not cost the user the rest. |
| **No clarification round loop.** `ParseOutcome` here is `draft \| declined`. Low-confidence rows are surfaced in the confirm UI instead of asking the model a follow-up question. | Two clarification rounds per line × 20 lines is a bad product. The confirm screen already asks the human. |
| **No widget, no cross-process DB read.** The App Group container exists only if the Share Extension needs a one-way inbox (§5.1), and the extension never opens the database. | Nothing to show on a widget in v1. Keep the connection story simple. |
| **Pricing is open, not inherited.** `workout-logger` is $4.99 up front; `a-new-word-every-day` is free with no IAP. Either has precedent. | See §13. |

---

## 4. Core loop and screens

1. **Add recipe** (URL / paste / photo) → parse → **Confirm** screen → Save.
2. **Recipes** screen: list of saved recipes, each with a "cooking this" toggle. Swipe to delete (confirm).
3. **List** screen: merged list from toggled recipes plus manual items, grouped by canonical ingredient, check-off persists.
4. Toggle recipes on and off → list regenerates → check state survives per canonical ingredient (rules in §9).

### 4.1 Screens

Three tabs: **List** (default), **Recipes**, **Add**.

- **Onboarding** (first launch only): `LFWOnboardingScaffold` over `LFWOnboardingBackground`, two pages, `.preferredColorScheme(.dark)` like the siblings. Page one says what it does; page two makes the privacy promise in one sentence, including the one page fetch, because that is the only thing a privacy-minded user will wonder about. Closure-based `onFinish` sets the flag.
- **List**: grouped by category; ingredient headings are the checkable unit (§9). A slim **Done shopping** action at the bottom; gear → Settings.
- **Recipes**: `LFWCard` rows, title in the display face, source kind + line count in chrome type, a "cooking this" toggle on the row. Swipe to delete, confirmed.
- **Add**: three `LFWCTAButtonStyle` entries (Link, Paste, Photo) → **Confirm** (§7.5) → Save.
- **Settings**: theme picker (palette + typeface, the same picker the word app built), seed version, Clear checked, Deselect all, privacy, Acknowledgements (OFL fonts, seed CC0).
- **Empty states** use `LFWEmptyState`: List with nothing selected deep-links to Recipes; Recipes with nothing saved deep-links to Add. No screen is ever blank.

### 4.2 Design

The word app is the visual reference. Reuse it; do not restyle.

- **Theme**: `LFWThemeConfig` stored in the injectable settings store; `LFWThemedBackground` behind every screen; **Forest** default (deep green gradient, gold accent). The full `LFWPalette` picker ships because it already exists and costs nothing.
- **Type by role, never by whim** (style guide rule): **Fraunces** for recipe titles, ingredient headings on the list, and empty-state titles; **Inter** for rows, quantities, units, buttons, and all chrome. Numerals are always Inter. Fall back to system fonts when fonts aren't bundled so tests and CI never depend on `fetch_fonts.sh`.
- **Color**: only `LFWColors` and palette tokens. The Confirm UI's "highlighted" state uses the on-palette `warning` tone, alias-refusal uses `danger`, a successful save uses `success`. No system `.green` / `.red` anywhere; the design-system sync guard plus code review enforce it.
- **Motion and touch**: `LFWHaptics.selection()` on check-off and toggle, `.success()` on save, `.warning()` on a refused alias. Checked headings settle to the bottom of their category with the default spring; nothing else animates.
- **Restraint**: one display moment per screen (the recipe title, the ingredient name). Everything else is quiet chrome. "Clean, but not generic."

---

## 5. Input paths

Priority order is also build order. Each path produces `[String]` raw lines plus a `RecipeSource` (kind, ref, title guess, `servings_text`).

| Path | Mechanism | LLM needed? |
|---|---|---|
| URL (paste + Share Extension) | Fetch page, extract schema.org `Recipe` → `recipeIngredient[]` | No for extraction; yes for line → structured (fallback: regex, §7.3) |
| Pasted text | Split lines, strip bullets/numbering | Same |
| Photo | Still image → `VNRecognizeTextRequest` (accurate mode, language correction on) → lines | Same |

Photo is the weakest path (multi-column cookbook layouts, drop caps, run-on lines). Ship it, but it does not get to drive pipeline design.

### 5.1 URL

**Fetch policy** — this is the app's only network call, and it must be describable in one sentence in the privacy copy: *"When you give it a link, the app downloads that page, once, and nothing else."*

- `https` only (ATS default, no exceptions). `http` links are refused with a clear message.
- Single `GET` of the exact URL the user gave. Follow at most 5 redirects, same scheme.
- No cookies, no stored credentials, no JavaScript, no sub-resources (images, scripts, CSS never fetched).
- Timeout 15 s, response cap 3 MB, `Accept: text/html`, a plain identifying `User-Agent`.
- No retries without a user tap.

**Extraction**, in order:

1. `<script type="application/ld+json">` blocks → find a node with `@type` `Recipe` (handle `@graph`, arrays, and `@type` as an array). Take `recipeIngredient`, `name`, `recipeYield`.
2. Microdata: elements with `itemprop="recipeIngredient"` (older WordPress recipe plugins).
3. Nothing found → show "Couldn't find a recipe on this page" with two buttons: *Paste the ingredients instead* (opens Paste pre-filled with nothing) and *Open in Safari*.

Store `source_ref` = final URL after redirects. HTML is parsed once and discarded; we keep only the raw lines. We never store the page.

**Share Extension** does zero parsing and zero networking. It writes `{url, sharedAt}` (or `{text, sharedAt}` for shared plain text) into an App Group inbox — a small JSON file — and shows "Added. Open Recipe to Grocery List to finish." The app drains the inbox on foreground and opens the Confirm flow. This is the only use of the App Group; the extension never links the store. Extension memory limits and the lack of Foundation Models access in extensions are why the extension does nothing clever.

### 5.2 Pasted text

- Split on newlines; trim; drop empty lines.
- Strip leading bullets, dashes, `*`, `•`, numbering (`1.`, `1)`, `①`).
- Lines ending in `:` with no digit are **section headers** ("For the sauce:"). They are not ingredients. They appear in the Confirm UI as greyed dividers so the user sees where they went, and are not stored.
- Everything else is a raw line.

### 5.3 Photo

- `PHPickerViewController` or camera → one image (no multi-page in v1).
- `VNRecognizeTextRequest`, `.accurate`, `usesLanguageCorrection = true`, English.
- Sort observations top-to-bottom, left-to-right; merge boxes whose vertical centers are within half a line height into one line. Two-column pages will interleave; the user fixes it in Confirm. Document the limitation in-app ("Works best on a single column of ingredients").
- Then the same header/bullet stripping as 5.2.

---

## 6. Data model

Raw SQL, app-owned, CHECK constraints on closed vocabularies. `Schema.latestVersion = 1` at v1 ship. Naming follows `workout-logger` (`id` + `slug`, snake_case, `TEXT` ISO-8601 timestamps).

```sql
CREATE TABLE ingredients (
    id              INTEGER PRIMARY KEY,
    slug            TEXT NOT NULL UNIQUE,            -- import/export key, never changes
    canonical_name  TEXT NOT NULL,                   -- user-renamable; seed never overwrites
    category        TEXT NOT NULL DEFAULT 'other'
                    CHECK (category IN ('produce','dairy','meat','seafood','bakery','pantry','frozen','other')),
    is_custom       INTEGER NOT NULL DEFAULT 0,      -- 1 = user-created via Confirm
    created_at      TEXT NOT NULL
);

CREATE TABLE ingredient_aliases (
    alias           TEXT PRIMARY KEY,                -- normalized (§7.1); PK = one owner per term
    ingredient_id   INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
    is_custom       INTEGER NOT NULL DEFAULT 0       -- 1 = written by a "same as…" tap
);

CREATE TABLE recipes (
    id              INTEGER PRIMARY KEY,
    title           TEXT NOT NULL,
    source_kind     TEXT NOT NULL CHECK (source_kind IN ('url','text','photo')),
    source_ref      TEXT,                            -- final URL for 'url'; NULL otherwise
    servings_text   TEXT,                            -- raw recipeYield, display only
    raw_lines       TEXT NOT NULL,                   -- JSON array of the lines we were given
    is_selected     INTEGER NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

CREATE TABLE recipe_ingredients (
    id              INTEGER PRIMARY KEY,
    recipe_id       INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    ingredient_id   INTEGER REFERENCES ingredients(id) ON DELETE SET NULL,  -- NULL = kept as free text
    raw_line        TEXT NOT NULL,                   -- always kept, verbatim
    name            TEXT NOT NULL,                   -- cleaned name as written ("veggie broth")
    quantity        REAL,                            -- parsed, never converted
    unit_key        TEXT,                            -- normalized unit (§8) or NULL
    unit_text       TEXT,                            -- unit as written, for display
    note            TEXT,                            -- "diced", "divided", "2–3"
    resolution      TEXT NOT NULL
                    CHECK (resolution IN ('exact','alias','loose','fuzzy','embedding','llm','user','none')),
    sort_order      INTEGER NOT NULL
);

CREATE TABLE check_state (
    ingredient_id   INTEGER PRIMARY KEY REFERENCES ingredients(id) ON DELETE CASCADE,
    checked_at      TEXT NOT NULL                    -- row present = checked
);

CREATE TABLE manual_items (
    id              INTEGER PRIMARY KEY,
    text            TEXT NOT NULL,
    checked_at      TEXT,                            -- NULL = unchecked
    created_at      TEXT NOT NULL
);
```

Rules

- `recipe_ingredients.raw_line` is never edited. Canonicalization is additive. `raw_lines` on the recipe lets a future pipeline re-parse without re-fetching.
- `ingredient_id` may be NULL only when the user explicitly chose *Keep as text* in Confirm. Those rows appear on the list under **Other** as plain text and cannot be merged with anything. This is how "never dropped" and "never guess" coexist.
- `resolution` records *how* the row got its ingredient. It drives the Confirm highlight (§7.5), and later lets us measure the pipeline on real data without telemetry.
- `check_state` is presence-based and keyed by canonical ingredient, so checking survives list regeneration. Rows are removed when their ingredient is no longer contributed by any selected recipe (§9).
- There is no persisted `list_item` table. The list is computed (§9). Persisting derived membership was the one piece of hidden state in v0.1 and it is gone.
- Seed: `Resources/seed_ingredients.json`, generated by `scripts/build_seed.py` from `scripts/seed_source.json` (the source of record, hand-authored, dedicated CC0, same posture as the word corpus). The build script validates the invariants in §3 and fails on duplicates. A few hundred common items with category and curated aliases (`vegetable broth` ← `veggie broth`, `vegetable stock`; `scallion` ← `green onion`, `spring onion`; `cilantro` ← `coriander leaf`, `fresh coriander`). Same loader and upsert semantics as `seed_exercises.json`, same invariant tests. Seed file is bundled into the app and test targets.
- Deleting a recipe cascades its rows and triggers the same check-state GC as deselecting it.
- Deleting or merging *ingredients* is not in v1 (only creation and alias growth). Merge lands with a learnings entry when it does.

---

## 7. Parse pipeline

Input: `[String]` raw lines + `RecipeSource`. Output: `RecipeDraft` for the Confirm UI, then the store. Four stages, each a pure function with fixture tests.

### 7.1 Normalize (always)

Applied to names and aliases before any matching. Deterministic and shared with the alias table's PK so the two can never disagree.

- Lowercase, Unicode NFKC, strip diacritics, collapse whitespace, trim.
- Strip trailing punctuation and parentheticals `(...)`.
- Remove a leading article (`a`, `an`, `the`).
- Singularize one trailing `s` / `es` when the word is longer than 3 characters (`tomatoes` → `tomato`, but `hummus` stays). Same "loose key" idea as `WorkoutStore.looseKey`.

### 7.2 Structure (always: regex splitter)

Split a raw line into `(quantity, unit_text, name, note)`. This runs on every device; the LLM only refines it.

- Quantity grammar: integers, decimals, ASCII fractions (`1/2`, `1 1/2`), Unicode fractions (`½`, `1½`), ranges (`2-3`, `2 to 3`, `2–3` → quantity = lower bound, note gets the range text), words `one`…`twelve`, `a`/`an` before a unit (`a pinch`) → 1.
- Unit: longest match against the unit table (§8) immediately after the quantity, with optional trailing `.` and `of`.
- Note: everything after the first comma, plus recognized prep words at the end of the name (`diced`, `minced`, `chopped`, `divided`, `to taste`, `optional`, `for serving`).
- Name: what's left. If nothing is left, the line is `unresolved` with `name = raw_line`.

### 7.3 Refine (LLM, when available)

One `LanguageModelSession` request per recipe, not per line. Instructions include the normalized names of all seed and custom ingredients so `canonicalGuess` is anchored, and the rule that it may not invent quantities.

```swift
@available(iOS 26.0, *)
@Generable struct ModelIngredientRow {
    @Guide(description: "The input line, unchanged.")
    let rawLine: String
    @Guide(description: "Ingredient name as written, cleaned of quantity, unit, and prep notes.")
    let name: String
    @Guide(description: "Best canonical grocery name for this ingredient, e.g. 'vegetable broth' for 'veggie stock'.")
    let canonicalGuess: String
    @Guide(description: "Numeric amount if the line states one; otherwise nil. Never invent one.")
    let quantity: Double?
    @Guide(description: "Unit exactly as written, or nil.")
    let unit: String?
    @Guide(description: "Preparation or usage note such as 'diced' or 'divided', or nil.")
    let note: String?
    @Guide(description: "high if the line is an unambiguous single ingredient; medium if a reasonable guess; low if unsure or the line is not an ingredient.")
    let confidence: String   // high | medium | low
}

@available(iOS 26.0, *)
@Generable struct ModelRecipeParse {
    let rows: [ModelIngredientRow]
    @Guide(description: "Short warning if some lines were not ingredients or could not be read; otherwise empty.")
    let warning: String
}
```

Mapping back (FM-free, always compiled, unit-tested, mirrors `ModelDraftMapping`):

- Rows are matched to input lines by `rawLine`. A model row whose `rawLine` doesn't match any input, or an input line the model skipped, falls back to the regex result for that line. The model can never add or remove lines.
- Unknown `confidence` string → `low`. Non-finite or negative `quantity` → nil. A model `quantity` where the regex found none → nil (the model may not invent numbers).
- The whole response fails validation (`declined`) only if it is unparseable; then every line uses regex + layers 0–3 and the UI says "Parsed without on-device AI".

### 7.4 Resolve (layers, per row, first hit wins)

Input is the normalized `name` (regex or LLM). `canonicalGuess` is only consulted at layer 4.

| Layer | Method | Writes `resolution` | Default treatment |
|---|---|---|---|
| 0 | exact `canonical_name` match (NOCASE) | `exact` | resolved |
| 1 | `ingredient_aliases` hit | `alias` | resolved |
| 1.5 | loose key (7.1 applied to both sides) against names and aliases | `loose` | resolved |
| 2 | fuzzy: `max(jaroWinkler(whole), tokenAverage)` ≥ threshold (start 0.78, recalibrate) against names and aliases | `fuzzy` | resolved, highlighted |
| 3 | `NLContextualEmbedding` mean-pooled cosine ≥ threshold (start 0.85) when fuzzy is below its escalation bar; additive, never displaces a fuzzy hit | `embedding` | resolved, highlighted |
| 4 | run layers 0–1.5 again on the LLM's `canonicalGuess`; if it hits, that ingredient is the suggestion | `llm` | suggested, requires tap |
| — | nothing hit | `none` | **new ingredient**, requires tap |

Two protections carried over from exercises: an alias can have one owner (PK), and two existing canonicals are never auto-merged by any layer. Watch-outs specific to food, to encode in the golden corpus: substring traps (`cream` vs `ice cream` vs `sour cream`, `chicken` vs `chicken broth`), and modifiers that change identity (`smoked paprika` ≠ `paprika`, `brown sugar` ≠ `sugar`). Fuzzy and embedding thresholds will likely end up *tighter* than the workout values for this reason.

### 7.5 Confirm UI

One row per raw line, in source order, with section-header dividers greyed. Row state is a function of `resolution` and `confidence`:

| State | Looks like | User can |
|---|---|---|
| Resolved (exact / alias / loose, high) | canonical name, quantity + unit, note | tap to change ingredient, edit fields |
| Resolved, highlighted (fuzzy / embedding, or medium) | same, `warning`-tone dot, "matched to *X*" | confirm by leaving it, or change |
| Suggested (llm) | "Looks like *X*" with **Use** button | Use → writes an alias `name → X` |
| New (none / low) | name in bold, "New ingredient" | **Create** (new canonical, `is_custom`), **Same as…** (picker → writes alias), **Keep as text** (`ingredient_id NULL`) |
| Not an ingredient | greyed | Remove, or keep as text |

The **Same as…** and **Use** taps are how the alias table grows: `ingredient_aliases (alias: normalize(name), ingredient_id, is_custom: 1)`. If that alias already exists for a different owner (the PK), the tap is refused with "*name* already means *Y*" — the user picks explicitly. The model never writes an alias.

Save is disabled until no row is in the *New* state. Everything else has a default the user can accept by tapping Save.

### 7.6 Devices without Apple Intelligence

Stages 7.1, 7.2, 7.4 layers 0–3, and 7.5 run unchanged. There is no layer 4, so more rows land in *New*. Copy says "On-device AI isn't available on this device; a few more rows may need a tap." This path is a first-class gate (§12, gate 9), not an afterthought, and CI proves both branches compile (the `foundation-models-guard` job).

---

## 8. Units policy (v1)

No conversion, no density tables, no "about 2 cups". The list shows one heading per canonical ingredient with its constituent lines underneath:

```
☐ Vegetable broth
    2 cups — Lentil soup
    500 ml — Risotto
☐ Garlic
    3 cloves — Lentil soup
    2 cloves — Risotto          →  5 cloves
☐ Parsley
    — Lentil soup               (no quantity given)
```

**Unit table** (`unit_key` ← accepted spellings). Starting set; extend from the golden corpus:

| key | accepted |
|---|---|
| `tsp` | tsp, teaspoon(s), t |
| `tbsp` | tbsp, tablespoon(s), T, tbs |
| `cup` | cup(s), c |
| `oz` | oz, ounce(s) |
| `lb` | lb(s), pound(s) |
| `g` | g, gram(s) |
| `kg` | kg, kilogram(s) |
| `ml` | ml, milliliter(s), millilitre(s) |
| `l` | l, liter(s), litre(s) |
| `clove` | clove(s) |
| `can` | can(s), tin(s) |
| `bunch` | bunch(es) |
| `pinch` | pinch(es) |
| `piece` | piece(s), whole |
| `slice` | slice(s) |
| `stick` | stick(s) |
| `head` | head(s) |
| `sprig` | sprig(s) |
| `package` | package(s), pkg, packet(s) |

- **Sum** only when every contributing line has a non-nil `quantity` and the same `unit_key` (including both NULL: "2 onions" + "1 onion" → 3). Show the sum to the right of the lines, keep the lines. Never sum across keys, never sum when any line lacks a quantity.
- Fractions display as fractions when the value is one of the common eighths/thirds; otherwise one decimal.
- `T` vs `t` is case-sensitive in the splitter (the one place normalization does not lowercase first).

---

## 9. Grocery list behavior

The list is a **pure function** of `(selected recipes, manual items, check_state)`. No hidden list state, no cached rows. Rebuild on every read; it is a few hundred rows at most.

- **Membership**: every `recipe_ingredients` row whose recipe `is_selected`, grouped by `ingredient_id`; rows with NULL `ingredient_id` group under **Other** as text; manual items group under **Other** too.
- **Ordering**: by category in store order (produce, bakery, dairy, meat, seafood, frozen, pantry, other), then canonical name. Category grouping is a v1 decision, not open (§13 closes it).
- **Checking** an ingredient heading checks it across all recipes contributing to it. Individual lines are not checkable. Checked headings sink to the bottom of their category, not out of view.
- **Check-state survival**: check state lives on the ingredient. Deselecting recipe A while recipe B still contributes the ingredient keeps it checked. When *no* selected recipe contributes it, the `check_state` row is deleted in the same transaction (otherwise re-selecting a recipe next week shows stale checks). This GC is the only side effect of a selection toggle.
- **Manual items** are checked/unchecked individually and are never merged with recipe ingredients (no resolution runs on them; that is what Add recipe → paste is for).
- **Destructive actions**, both confirmed: *Clear checked* (deletes all `check_state` rows and checked manual items) and *Deselect all recipes*. "Done shopping" is the pair of them, one button, one confirmation.
- **v1.1 candidate**: export the current list to Reminders via `EventKit`. Not v1; the seam is that the list is already a value type.

---

## 10. Privacy and NOTICE

- **Network**: exactly one kind of request (§5.1). `docs/privacy.md`, the App Store privacy label ("Data Not Collected"), and the in-app privacy screen must all describe it in the same words. `PrivacyInfo.xcprivacy` declares no tracking, no required-reason APIs beyond what SQLite/file timestamps need.
- **Photos**: image is processed in memory and never stored. Camera/photo permission is opt-in, requested at first use with the reason string "To read ingredients off a page".
- **LLM**: on-device Foundation Models only; copy uses the family's wording, "no **cloud** AI".
- **NOTICE.md**: inherit the copy rule and reuse log. Expected v1 entries: `lfwdesignsystem` (same author), XcodeGen (MIT, not shipped), Fraunces and Inter (SIL OFL 1.1, bundled, `OFL.txt` shipped), the seed ingredient list (own-authored, CC0; a scraped list from a licensed dictionary or a recipe site is *Never*), and any fraction/unit tables or string-similarity code ported from elsewhere (attribution in the file, per the FSRS precedent).
- **No analytics**, no crash reporter, no third-party SDKs. `resolution` on each row is the only "telemetry" and it never leaves the DB.

---

## 11. Testing

- **Golden corpus**: `Tests/Fixtures/ingredient_lines.json`, a few hundred real-world lines (paste, JSON-LD, OCR-shaped) with expected `(quantity, unit_key, name, note, expected slug or null)`. Layers 0–3 and the splitter are tested against it; the pass rate is printed in test output and any drop fails the build. This corpus is how thresholds get calibrated, replacing the workout values.
- **JSON-LD fixtures**: saved HTML from a handful of recipe sites (with `@graph`, arrays, microdata-only). Extraction tests run offline; there is no network in tests.
- **Store tests**: one write path, migrations from fresh and from v1, seed upsert idempotency, alias PK refusal, check-state GC on deselect and delete, list regeneration as a pure function.
- **Mapping tests**: FM-free `ModelIngredientMapping` against hand-written model outputs including skipped lines, invented lines, invented quantities, junk confidence.
- **CI**: `ios-tests.yml` (unit tests on the simulator + `foundation-models-guard` on `macos-26`) and `checks.yml` (design-system sync, store boundary, App Group identifier sync if the extension lands). Both inherited.

---

## 12. PR gates

Sequential; each PR is one gate, lands with tests, and adds a `docs/learnings/` entry when it changes a decision here. "Done when" is the review bar.

| # | Gate | Done when |
|---|---|---|
| 0 | Scaffold: XcodeGen + `SQLiteDB` + `Theme` + CI workflows + PR template + STANDARDS from `workout-logger`; `lfwdesignsystem` synced from the word repo, `fetch_fonts.sh` / `check_fonts_sync.sh` / `release.sh` / `setup_signing.sh`, `LFWThemeConfig` wiring, onboarding, NOTICE, privacy.md | Empty themed app builds and tests green on CI; `check_designsystem_sync` and `check_fonts_sync` pass |
| 1 | Schema v1 + migrations + `scripts/seed_source.json` → `build_seed.py` → `seed_ingredients.json` + seed loader + invariant tests + `docs/prior-art-and-licensing.md` | Fresh install seeds; second launch is a no-op; renamed canonical survives re-seed |
| 2 | Paste → splitter (7.2) → Confirm UI (7.5, layers 0–1.5 only) → save | A pasted recipe round-trips to the DB with every raw line kept |
| 3 | Resolution layers 2–3, alias creation via *Same as…* / *Use*, golden corpus test | Corpus pass rate reported; alias PK refusal has a UI path |
| 4 | Foundation Models adapter: `ModelRecipeParse`, mapping layer, per-recipe request, availability gating, guard job | Same recipe parses on an FM device and a non-FM simulator; both branches in CI |
| 5 | Recipes screen: list, select toggle, delete with cascade + GC | Toggle and delete are store transactions; no view touches `db` |
| 6 | List screen: regeneration, category order, heading check-off, sums per §8, manual items, Done shopping | List is a pure function with tests; check state survives toggles as specified |
| 7 | URL import: fetch policy, JSON-LD + microdata extraction, fixtures; Share Extension with App Group inbox | Offline extraction tests; privacy copy updated in the same PR |
| 8 | Photo import: picker/camera → Vision → lines → pipeline | Single-column page works end to end; limitation copy in place |
| 9 | Non-AI device path verified end to end, copy for it, corpus pass rate without layer 4 recorded | Manual QA on a non-Apple-Intelligence device documented in a learnings entry |
| 10 | Empty states, NOTICE audit, privacy label, `docs/app-store-metadata.md` (no price terms in name/subtitle), screenshots via the word app's capture script | TestFlight build archived via `scripts/archive_for_testflight.sh` |

---

## 13. Open decisions

Every row is the owner's call; nothing here is decided by a gate landing. "Decide
by" is the gate that cannot start until the answer is in this document. Rows
marked **Closed** are decided and listed only so the reasoning is on record.

| Question | Lean | Decide by |
|---|---|---|
| App Store name | "Recipe to Grocery List" is descriptive and matches the repo; check availability | Gate 10 |
| Free vs paid | Free (no server, no ongoing cost; the word app is the precedent). Paid up front is equally honest and is the workout app's precedent. Either is fine; "simple" is not the reason. | Gate 0 (affects README + license posture) |
| Source license | Family has both: source-available all-rights-reserved (`workout-logger`) and MIT (`a-new-word-every-day`). Tie to the pricing decision. | Gate 0 |
| Category grouping | **Closed**: ship the eight categories in §6 in store order. Dropping grouping saves nothing and the seed carries the data anyway. | — |
| Photo capture API | **Closed**: still photo + `VNRecognizeTextRequest`. | — |
| May `canonicalGuess` propose something outside the seed + custom set? | Yes, unconstrained; but it can only ever produce a *suggestion*, and a guess that matches nothing lands in *New* like any other row. Model proposes, app confirms. | Gate 4 |
| Fuzzy / embedding thresholds | Start at workout values (0.78 / 0.85), recalibrate on the corpus, expect tighter | Gate 3 |
| Share Extension in v1 or v1.1 | v1, gate 7, but paste-a-URL ships first and the extension can slip without blocking release | Gate 7 |
| Ingredient merge/rename UI | v1.1 | — |
| Theming | **Closed**: reuse `LFWThemeConfig` with Forest default and the existing palette/typeface picker. No new tokens, no new components unless the word repo gets them first. | — |

---

## Status & scope

**v1.0 — implemented, device verification outstanding.** Every gate in §12 has
landed on this branch in order: 0 scaffold, 1 schema + seed, 2 paste → splitter
→ Confirm → save, 3 fuzzy/embedding resolution + aliases + golden corpus, 4
Foundation Models adapter with per-row mapping, 5 Recipes screen, 6 List screen,
7 URL import + Share Extension inbox, 8 photo import, plus the copy, corpus
measurement and tooling for 9 and 10. The design above is unchanged except where
a learnings entry says otherwise.

What is **not** done, because it cannot be done where this was written (no
Swift toolchain — see `docs/learnings/001-scaffold-and-inheritance.md`):

- the first real `xcodebuild` (`bash scripts/fetch_fonts.sh && bash
  scripts/generate.sh && bash scripts/run_tests.sh`) and whatever it turns up;
- **gate 9** — manual QA on a device without Apple Intelligence, recorded in
  `docs/learnings/008-non-ai-path.md`;
- **gate 10** — the TestFlight archive via `scripts/archive_for_testflight.sh`,
  real app-icon artwork, the two §13 decisions (free vs paid, source license)
  and the checklist in `docs/app-store-metadata.md`.

### Implementation notes

Decision write-ups, one per gate, in `docs/learnings/`:

1. [001 — scaffold and inheritance](learnings/001-scaffold-and-inheritance.md): what was copied from which sibling at which revision; database in the app sandbox (not the App Group); typeface picker limited to the two bundled faces; license and price left open; placeholder icon; the no-toolchain constraint and the owner's first steps.
2. `002-seed-and-normalization.md`: the seed source of record, `build_seed.py`, the §7.1 normalizer and its Python mirror.
3. `003-fuzzy-thresholds.md`: the symmetric token metric, the substring traps, thresholds calibrated on the golden corpus.
4. `004-foundation-models-per-row-fallback.md`: `ModelIngredientMapping`, one session per recipe, why a bad row never declines the recipe.
5. `005-computed-list.md`: `GroceryListBuilder`, check-state GC, the sum rule.
6. `006-url-import-and-inbox.md`: the fetch policy as code, JSON-LD/microdata extraction, the Share Extension's one-way inbox.
7. `007-photo-import.md`: Vision configuration, line merging, the single-column limitation.
8. `008-non-ai-path.md`: the `refiner == nil` path end to end, corpus pass rate without layer 4, the manual QA record (gate 9).
9. `009-app-store-readiness.md`: privacy manifest, metadata, screenshots, NOTICE audit, the archive (gate 10).

History: **v0.2** (design only) superseded v0.1, which lived in a chat; it
corrected the inheritance section against the actual `workout-logger` source,
pulled the design/theming/fonts/release/seed-build/data-licensing patterns from
`a-new-word-every-day`, dropped the clarification loop, replaced persisted
`list_item` with computed membership + `check_state`, and added the fetch
policy, Share Extension inbox, per-row fallback, `resolution` provenance, *Keep
as text*, the check-state GC rule, the unit table, the golden corpus and "done
when" per gate.
