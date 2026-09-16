# 001 — Scaffold and inheritance (gate 0, and the gate-10 tooling)

What was copied from where, revision by revision, and the handful of decisions
the scaffold had to make before any feature could. Sibling revisions are the ones
SPEC §3 pins: `workout-logger@5bffddfb80fc` (2026-07-11) and
`a-new-word-every-day@e829bcc9c0dc` (2026-09-01, `lfwdesignsystem` 2.3.0).

## What came from where

| Here | Copied from | Changed |
|---|---|---|
| `project.yml` | workout `project.yml` (app/tests split, explicit `Info.plist`, `-lsqlite3`); word `project.yml` (archive/profile scheme actions, fonts as enumerated resources) | Widget target → Share Extension with a committed `Info.plist` (`INFOPLIST_FILE`, not `info:`); test target excludes `Fixtures` and bundles it flat |
| `project.local.yml.example`, `scripts/generate.sh`, `run_tests.sh`, `release.sh`, `setup_signing.sh`, `fetch_fonts.sh` | word `scripts/` (same names) | Scheme + fonts dir renamed; fetch list trimmed to Fraunces + Inter (same URLs) |
| `scripts/check_fonts_sync.sh` | word `scripts/check_fonts_sync.sh` | Source of truth flipped: the app's `Theme.bundledTypefaces` allowlist, mapped through `LFWTypeface.bundledFileName`, vs `Info.plist` vs the fetch script; no widget plist |
| `scripts/check_appgroup_sync.sh` | word `scripts/check_appgroup_sync.sh` | Swift path; "one distinct value" wording for app + extension |
| `scripts/check_store_boundary.sh` | workout `scripts/check_store_boundary.sh` | Write surface = `insertIngredientRow`, `insertAliasRow`, `gcCheckState`, `uniqueSlug`, `.db`; no Shared allowance for `SQLiteDB(`; new rule: nothing under `RecipeShareExtension/` may name `RecipeStore`, `SQLiteDB` or `import SQLite3`, and `Shared/` may not `import SQLite3`; 15 self-test fixtures |
| `scripts/archive_for_testflight.sh`, `run_simulator.sh`, `prepare_app_store_screenshots.sh` | workout `scripts/` | Scheme/bundle id; fonts fetched first; machine UDID → `SIM_UDID` override |
| `scripts/capture_app_store_screenshots.sh` | word `scripts/capture_app_store_screenshots.sh` | iPhone only, three shots (`01-list`, `02-recipes`, `03-add`), no Japanese set |
| `scripts/check_designsystem_sync.sh`, `lfwdesignsystem/` | word (synced, `CHECKSUMS.txt` verified) | Only `LICENSE` and `README.md` are per-repo (excluded from the checksum) |
| `.github/workflows/ios-tests.yml` | workout (two jobs incl. `foundation-models-guard` on `macos-26`); word (fetch fonts *before* `xcodegen generate`, `-retry-tests-on-failure -test-iterations 3`, UDID-pinned destination) | Scheme |
| `.github/workflows/checks.yml` | workout + word | Adds fonts sync, store boundary, `build_seed.py --check` + porcelain guard, golden-corpus fixture validation |
| `.github/STANDARDS.md`, `pull_request_template.md`, `ISSUE_TEMPLATE/*` | workout `.github/` | Rewritten for one write path `RecipeStore.save`, per-row not all-or-nothing, computed list, the fetch-policy sentence, no clarification loop; PR checklist adds seed-build, privacy-copy and citation items |
| `NOTICE.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/privacy.md`, `docs/app-store-review-notes.md` | workout | HealthKit/widget removed; App Group inbox + Share Extension + the single fetch added |
| `docs/app-store-metadata.md`, `docs/prior-art-and-licensing.md`, `Fonts/OFL.txt`, `Fonts/.gitkeep` | word | Guideline 2.3.7 note kept; OFL header lists only Fraunces and Inter |
| `RecipeToGroceryList/App/Info.plist` | workout (skeleton, camera/photo strings) + word (`UILaunchScreen` colour, `UIRequiresFullScreen`, `UIAppFonts`) | No URL scheme, no ATS exceptions |
| `Resources/PrivacyInfo.xcprivacy` | workout (UserDefaults `CA92.1` only) | Comment explains why not `1C8F.1`: the inbox is a file, not shared UserDefaults |
| `Storage/SQLiteDB.swift` | workout `Storage/SQLiteDB.swift` | Verbatim; doc comments re-pointed |

## Gate-0 decisions

**Database in the app sandbox, not the App Group.** The workout app puts its
SQLite file in the App Group because its widget reads it from another process.
Here nothing does: the Share Extension's whole job is to append a link or some
text to `inbox.json` and get out of the way (extension memory limits and no
Foundation Models access in extensions are the deeper reason — SPEC §5.1). So
`AppDatabase.databaseURL()` is `<Application Support>/recipes.sqlite`, the
extension compiles only its own folder plus `Shared/` (AppGroup, ShareInbox,
RecipeDateFormat), and `check_store_boundary.sh` makes the "never opens the
database" claim a CI failure rather than a comment. The App Group container
holds exactly one thing and the privacy policy can say so in one sentence.

**Typeface picker limited to the two bundled faces.** `LFWThemeConfig` knows
seven typefaces because the word app bundles all seven. This app bundles Fraunces
(display) and Inter (chrome) — the two the spec names — and `Theme.bundledTypefaces`
is `[.fraunces, .inter]`. Offering the other five would "work" in the sense that
`LFWTypography` falls back to a system face, but the user would pick "Literata"
and get New York. A picker that lies is worse than a shorter picker.
`check_fonts_sync.sh` was re-pointed at this allowlist so the three places the
list lives (Swift, `Info.plist`, fetch script) cannot drift, and it also refuses a
file name the design system doesn't know.

**License and price left open, per §13.** Both are the owner's call and tied to
each other (the family has both precedents). The scaffold therefore ships **no
root `LICENSE`**, and every place that would normally name one — `NOTICE.md`,
`CONTRIBUTING.md`, `SECURITY.md`, `lfwdesignsystem/LICENSE`, the README, the
PR template — says plainly that the decision is open and that the default (all
rights reserved) applies until it lands. `NSHumanReadableCopyright` carries the
copyright line only. The 1.0 checklist in `docs/app-store-metadata.md` lists
both decisions first, because the listing copy depends on them (no price words
anywhere in the name/subtitle/promo regardless — Guideline 2.3.7).

**Placeholder icon.** `AppIcon-1024.png` is a 1024×1024 flat forest-green
(`LFWColors.forest`, `#1F332B`) square with a centred gold (`LFWColors.gold`,
`#F8B500`) disc of 560 px, generated with pure Python (zlib + struct — no image
library in the authoring environment) and verified by re-reading its IHDR. It
exists so the asset catalog compiles and TestFlight accepts the archive; it is
not artwork. Replacing it is on the 1.0 checklist.

**Launch colour.** `LaunchBackground` is the same forest green as the onboarding
gradient's base so the launch frame doesn't flash white before `ThemedScreen`
paints (the word app's trick).

## The honest constraint: nothing here was compiled

There is **no Swift or Xcode toolchain in the environment this branch was
authored in**. Every Swift file was written to idiomatic Swift 5 against iOS 17,
reviewed across files, and mirrored on siblings that are known to build and ship;
everything that *could* be checked without Swift was: `project.yml` and the
workflows parse as YAML with the expected targets, every plist round-trips
through `plistlib`, the seed and the golden corpus are validated by Python, the
SQL was exercised in `sqlite3`, and every shell script passes `bash -n` and (for
the three guards) its own self-test or a stand-in tree. The first real
`xcodebuild` is therefore the actual verification gate for the whole branch.

The owner's first three commands, on a Mac with Xcode 16+:

```bash
bash scripts/fetch_fonts.sh    # Fraunces + Inter into Resources/Fonts/ (BEFORE generate)
bash scripts/generate.sh       # project.yml + project.local.yml → RecipeToGroceryList.xcodeproj
bash scripts/run_tests.sh      # build + the full XCTest suite on a pinned iPhone simulator
```

Expect compile errors before test failures; fix in place and re-run. Then, in
order: `docs/learnings/008-non-ai-path.md`'s manual QA on a device without Apple
Intelligence (gate 9), `bash scripts/archive_for_testflight.sh` (gate 10), and
the checklist in `docs/app-store-metadata.md`.

## What's intentionally absent

No `LICENSE`, no price in any copy, no real icon, no `docs/learnings/00N` for
gates 1–9 yet (they land as `002`–`009`; see the Status section of the spec), no
widget, no URL scheme, no ATS exceptions, no dependency.
