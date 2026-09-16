<div align="center">

# Recipe to Grocery List

A local-first iOS app that turns recipes into one grocery list. Share a link,
paste text, or photograph a page; confirm the ingredients; pick what you're
cooking; shop from a single merged, checkable list.

![Platform: iOS 17+](https://img.shields.io/badge/Platform-iOS%2017%2B-lightgrey.svg)
![Status: design](https://img.shields.io/badge/Status-design-F8B500.svg)

</div>

> **No account. No servers. No tracking. No cloud AI.** Recipes, ingredients,
> and your list live in on-device SQLite. The app makes exactly one kind of
> network request: when you hand it a link, it downloads that page, once, and
> nothing else.

Same family as [Private Workout Logger](https://github.com/lukefwalton/workout-logger)
and [A New Word Every Day](https://github.com/lukefwalton/a-new-word-every-day):
SwiftUI, on-device, shared design system, XcodeGen, one write path.

## What it will do

- **Capture** a recipe from a URL (Share Extension or paste, via schema.org
  `Recipe` JSON-LD), pasted text, or a photo (Vision OCR). Every path becomes
  the same thing: a list of raw ingredient lines.
- **Confirm** the parse. The app proposes quantity, unit, name, and a canonical
  ingredient for each line; you fix what's wrong and save. Unparsed lines are
  shown, never dropped.
- **Select** any saved recipes as "cooking this".
- **Shop** from one list grouped by ingredient and store category, with the
  lines from each recipe underneath. Amounts are summed only when the units
  match. Check state survives adding or removing recipes.

## How it's built (planned)

- **Storage** — raw `sqlite3`, forward-only migrations, a single
  `RecipeDraft → validate → transaction → save` write path, CI guard that no
  view touches the database. Inherited from the workout app.
- **Ingredient identity** — stable slugs, a seeded alias table with one owner
  per alias, and a deterministic-first resolution stack: exact → alias → loose →
  fuzzy → on-device embeddings → on-device LLM. Every layer proposes; the user
  confirms; the store writes.
- **On-device AI** — Apple Foundation Models on iOS 26 devices that have it,
  gated at compile time and at runtime. The app is fully usable without it.
- **Design** — `lfwdesignsystem` (vendored from the word app): Forest theme by
  default, Fraunces for display, Inter for chrome, user-selectable palettes.

## Documentation

This README is the overview. [docs/SPEC.md](docs/SPEC.md) is the normative
design document; when the two disagree, the spec wins and the README gets fixed.

- [docs/SPEC.md](docs/SPEC.md) — the v1 design: principles, what is inherited
  from the sibling apps and what deliberately isn't, data model, parse pipeline,
  units policy, list behavior, privacy, testing, PR gates, open decisions.

`docs/learnings/` will collect decision write-ups as gates land, following the
family convention.

## Status

Design only. No app code yet. The build order is the PR-gate table in
[docs/SPEC.md §12](docs/SPEC.md#12-pr-gates); gate 0 (scaffold) is next.

## Building

Nothing to build yet. When gate 0 lands the setup will match the siblings:

```bash
brew install xcodegen
cp project.local.yml.example project.local.yml   # set DEVELOPMENT_TEAM (gitignored)
bash scripts/fetch_fonts.sh                       # OFL variable fonts, not committed
bash scripts/generate.sh
```

## License

Copyright Luke F. Walton. License TBD; see [docs/SPEC.md §13](docs/SPEC.md#13-open-decisions).
