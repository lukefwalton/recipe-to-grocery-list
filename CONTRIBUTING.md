# Contributing

Recipe to Grocery List is **public source, copyright Luke F. Walton.** The
source license is still an open decision ([docs/SPEC.md §13](docs/SPEC.md#13-open-decisions));
until it is made there is deliberately no `LICENSE` file, which means the default
applies — all rights reserved. The code is visible so you can verify the privacy
posture; the App Store build is the official release.

By participating in the issue tracker you agree to abide by the
[Code of Conduct](CODE_OF_CONDUCT.md).

## Support & feedback

Having a problem with the app or the repo?

- **[GitHub Issues](https://github.com/lukefwalton/recipe-to-grocery-list/issues)** — bugs,
  questions, anything reproducible (include iOS version, app version, and whether
  Apple Intelligence is available on the device when you can). If a web page
  failed to import, the URL is enough — never paste the page.
- **[luke@lukefwalton.com](mailto:luke@lukefwalton.com)** — same, or if you prefer email.
  Preferred for security or privacy concerns.

Product page: [lukefwalton.com/recipe-to-grocery-list](https://lukefwalton.com/recipe-to-grocery-list/)

## What we do not accept (without prior agreement)

- Pull requests that add features, refactors, or dependency changes.
- Forks published to the App Store or redistributed as competing products.
- Use of this codebase beyond personal local audit/build without written permission.

If you have a concrete fix and believe it should land, open an issue first. We
can discuss whether a PR makes sense case by case.

## Building locally (audit / development)

There is no Swift toolchain in the authoring environment this branch was written
in, so the first real `xcodebuild` is the verification gate — see
[docs/learnings/001-scaffold-and-inheritance.md](docs/learnings/001-scaffold-and-inheritance.md).

```bash
brew install xcodegen
python3 -m pip install pyyaml                      # generate.sh merges YAML with PyYAML
cp project.local.yml.example project.local.yml   # set DEVELOPMENT_TEAM (never commit this file)
bash scripts/fetch_fonts.sh                       # Fraunces + Inter (OFL, not committed) — BEFORE generate
bash scripts/generate.sh
bash scripts/run_tests.sh                         # or open RecipeToGroceryList.xcodeproj and ⌘U
```

Register the App Group (`group.com.lukewalton.recipetogrocerylist`) for your team
if you sign with your own Apple Developer account — the Share Extension needs it
to hand a link to the app. For a fork, change `bundleIdPrefix` / bundle IDs in
`project.local.yml` and the App Group in *both* `project.yml` and
`RecipeToGroceryList/Shared/AppGroup.swift` (`scripts/check_appgroup_sync.sh`
keeps them honest).

CI runs the unit suite and a Foundation Models compile guard on macOS
(`.github/workflows/ios-tests.yml`) and the config guardrails on Ubuntu
(`.github/workflows/checks.yml`): design-system checksum, App Group sync, bundled
font list, store write-path boundary, seed regeneration, golden-corpus fixture
shape.

## Architecture ground rules (if we do accept a change)

The full doctrine is in [.github/STANDARDS.md](.github/STANDARDS.md); the short form:

- Local-first: on-device SQLite is the single source of truth.
- One write path: `RecipeDraft → validate → transaction → save` via `RecipeStore.save`.
- Model proposes, app confirms, app writes — the LLM, fuzzy and embedding layers never mutate the database.
- Per-row results, never all-or-nothing; nothing silently dropped.
- Honest numbers: no unit conversion, sums only when units match.
- Usable without AI; gated frameworks stay in one file each.
- Schema changes need migrations and tests. Seed changes go through `scripts/seed_source.json` + `build_seed.py`.
- Zero third-party dependencies. Comments cite the sibling file and revision for inherited code.

Third-party reuse is logged in [NOTICE.md](NOTICE.md). Found a security or
privacy issue? Please report it privately — see [SECURITY.md](SECURITY.md).
