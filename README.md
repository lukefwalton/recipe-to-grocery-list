<div align="center">

# Recipe to Grocery List

A local-first iOS app that turns recipes into one grocery list. Share a link,
paste text, or photograph a page; confirm the ingredients; pick what you're
cooking; shop from a single merged, checkable list.

![Platform: iOS 17+](https://img.shields.io/badge/Platform-iOS%2017%2B-lightgrey.svg)
![Status: 1.0 submitted for App Store review](https://img.shields.io/badge/Status-1.0%20submitted%20for%20App%20Store%20review-F8B500.svg)

</div>

> **No account. No servers. No tracking. No cloud AI.** Recipes, ingredients,
> and your list live in on-device SQLite. The app makes exactly one kind of
> network request: when you give it a link, the app downloads that page, once,
> and nothing else.

Free, no in-app purchases. Product page and support:
[lukefwalton.com/recipe-to-grocery-list](https://lukefwalton.com/recipe-to-grocery-list/)
· [privacy policy](https://lukefwalton.com/recipe-to-grocery-list/privacy/).

Same family as [A New Word Every Day](https://github.com/lukefwalton/a-new-word-every-day)
and [Private Workout Logger](https://github.com/lukefwalton/workout-logger)
(withdrawn October 2026): SwiftUI, on-device, shared design system, XcodeGen,
one write path.

## What it does

- **Capture** a recipe from a URL (Share Extension or paste, via schema.org
  `Recipe` JSON-LD with a microdata fallback), pasted text, or a photo (Vision
  OCR). Every path becomes the same thing: a list of raw ingredient lines.
- **Confirm** the parse. The app proposes quantity, unit, name, note and a
  canonical ingredient for each line; you fix what's wrong and save. Lines it
  can't place are shown as *New ingredient* — create one, match it to one you
  have, or keep it as text. Nothing is ever dropped.
- **Select** any saved recipes as "cooking this".
- **Shop** from one list grouped by ingredient and store aisle, with the lines
  from each recipe underneath. Amounts are summed only when the units match;
  nothing is ever converted. Check state lives on the ingredient and survives
  adding or removing recipes. *Done shopping* clears it in one tap.

## How it's built

- **Storage** — raw `sqlite3`, forward-only migrations, a single
  `RecipeDraft → validate → transaction → save` write path
  (`RecipeStore.save`), and a CI guard that no view touches the database and
  the Share Extension never opens it. Inherited from the workout app.
- **Ingredient identity** — stable slugs, a hand-authored CC0 seed built from
  `scripts/seed_source.json`, an alias table with one owner per alias, and a
  deterministic-first resolution stack: exact → alias → loose → fuzzy
  (Jaro–Winkler, symmetric tokens) → on-device embeddings → on-device LLM.
  Every layer proposes; the user confirms; the store writes.
- **Parsing** — a regex splitter that runs everywhere, refined per recipe by
  Apple Foundation Models on iOS 26 devices that have it (gated at compile time
  and at runtime), mapped back **per row** so one unreadable line never costs
  the rest. Measured against a golden corpus whose pass rate CI prints and
  asserts.
- **The list** — a pure function of `(selected recipes, manual items, check
  state)`; no persisted list table.
- **Import** — one `https` GET, five same-scheme redirects at most, no cookies,
  no JavaScript, no sub-resources, 15 s, 3 MB; the page is parsed once and
  discarded. The Share Extension writes a one-way inbox file in the App Group
  and does nothing else.
- **Design** — `lfwdesignsystem` (vendored from the word app): Forest theme by
  default, Fraunces for display, Inter for chrome, the palette picker; the
  typeface picker offers only the two bundled faces.

## Documentation

This README is the overview. [docs/SPEC.md](docs/SPEC.md) is the normative
design document; when the two disagree, the spec wins and the README gets fixed.

- [docs/SPEC.md](docs/SPEC.md) — the v1 design: principles, inheritance, data
  model, parse pipeline, units policy, list behavior, privacy, testing, the
  [PR-gate table](docs/SPEC.md#12-pr-gates) the build followed, open decisions.
- [docs/privacy.md](docs/privacy.md) — the privacy policy; the in-app screen
  and the App Store label use the same words.
- [docs/prior-art-and-licensing.md](docs/prior-art-and-licensing.md) — what was
  reused, what was deliberately not, and why the seed is our own.
- [docs/app-store-metadata.md](docs/app-store-metadata.md) and
  [docs/app-store-review-notes.md](docs/app-store-review-notes.md) — listing
  copy (no price words), review notes, the 1.0 checklist.
- [docs/learnings/](docs/learnings/) — decision write-ups, one per gate, 001–012:
  [scaffold and inheritance](docs/learnings/001-scaffold-and-inheritance.md),
  the seed and normalizer, [fuzzy thresholds calibrated on the
  corpus](docs/learnings/003-fuzzy-thresholds.md), per-row model fallback, the
  computed list, URL import and the inbox, photo import, [the device without
  Apple Intelligence](docs/learnings/008-non-ai-path.md), App Store readiness,
  [the CI guards that stand in for a compiler](docs/learnings/010-guards-without-a-compiler.md),
  [the first read-through](docs/learnings/011-first-read-through.md), and
  [release prep](docs/learnings/012-release-prep.md). [docs/publishing-source.md](docs/publishing-source.md)
  is the going-public checklist.
- [.github/STANDARDS.md](.github/STANDARDS.md) — the doctrine PRs are reviewed
  against. [NOTICE.md](NOTICE.md) — the reuse log.

## Status

**1.0 (build 1) submitted to App Review, October 2026.** Every gate in SPEC §12
landed in order; the real app icon shipped with the archive; the Support and
Privacy pages are live. Pricing is decided (free) and so is
the license (MIT), both in [012](docs/learnings/012-release-prep.md). The App Store link lands here and on the
product page once the app is approved.

## Building

```bash
brew install xcodegen
python3 -m pip install pyyaml                      # generate.sh merges YAML with PyYAML
cp project.local.yml.example project.local.yml   # set DEVELOPMENT_TEAM (gitignored)
bash scripts/fetch_fonts.sh                       # Fraunces + Inter, OFL, not committed — BEFORE generate
bash scripts/generate.sh
bash scripts/run_tests.sh                         # or open RecipeToGroceryList.xcodeproj and ⌘U
```

Register the App Group (`group.com.lukewalton.recipetogrocerylist`) for your team;
the Share Extension needs it. CI: `.github/workflows/ios-tests.yml` (unit tests +
a Foundation Models compile guard) and `checks.yml` (design-system checksum, App
Group sync, font list, store boundary, seed regeneration, golden-corpus fixture,
the SQL schema executed and diffed against the spec, and a source check that every
file is compiled and imports what it uses).

## License

Code: MIT, see [LICENSE](LICENSE), including the vendored `lfwdesignsystem/`.
Bundled fonts are SIL OFL 1.1 and the ingredient seed is CC0.
[NOTICE.md](NOTICE.md) logs third-party references (fonts, the seed vocabulary,
build tooling). Going public? See [docs/publishing-source.md](docs/publishing-source.md).
