<div align="center">

# Recipe to Grocery List

A local-first iOS app that turns recipes into one grocery list. Share a link,
paste text, or photograph a page; confirm the ingredients; pick what you're
cooking; shop from a single merged, checkable list.

![Platform: iOS 17+](https://img.shields.io/badge/Platform-iOS%2017%2B-lightgrey.svg)
![Status: v1 implemented — device verification pending](https://img.shields.io/badge/Status-v1%20implemented%20%E2%80%94%20device%20verification%20pending-F8B500.svg)

</div>

> **No account. No servers. No tracking. No cloud AI.** Recipes, ingredients,
> and your list live in on-device SQLite. The app makes exactly one kind of
> network request: when you give it a link, the app downloads that page, once,
> and nothing else.

Same family as [Private Workout Logger](https://github.com/lukefwalton/workout-logger)
and [A New Word Every Day](https://github.com/lukefwalton/a-new-word-every-day):
SwiftUI, on-device, shared design system, XcodeGen, one write path.

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
- [docs/learnings/](docs/learnings/) — decision write-ups per gate, starting
  with [001 — scaffold and inheritance](docs/learnings/001-scaffold-and-inheritance.md).
- [.github/STANDARDS.md](.github/STANDARDS.md) — the doctrine PRs are reviewed
  against. [NOTICE.md](NOTICE.md) — the reuse log.

## Status

**v1 implemented on this branch, gate by gate** (SPEC §12, gates 0–8 and the
tooling for 9–10). The code was written without a Swift toolchain, so the
remaining work is verification on a Mac and a device: the first `xcodebuild`,
manual QA on a phone without Apple Intelligence (gate 9), and a TestFlight
archive (gate 10). Two decisions stay open by design — free vs paid and the
source license (SPEC §13).

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
Group sync, font list, store boundary, seed regeneration, golden-corpus fixture).

## License

Copyright Luke F. Walton. License TBD; see [docs/SPEC.md §13](docs/SPEC.md#13-open-decisions).
Until it is decided there is deliberately no `LICENSE` file, so all rights are
reserved; the source is public so the privacy posture can be audited.
