# Notices & Attributions

Recipe to Grocery List (RecipeToGroceryList) and LFWDesignSystem
Copyright (c) 2026 Luke F. Walton

**License:** MIT, see [LICENSE](LICENSE) — decided October 2026
(`docs/learnings/012-release-prep.md`), the `a-new-word-every-day` precedent.
The app and `lfwdesignsystem/` are original work by the same author and carry
the same license.

Third-party components referenced by this project remain under their own licenses.
The copy rule for scavenged code (internal discipline, inherited from
`workout-logger` `NOTICE.md` at `5bffddfb80fc`):

```
Copy:        MIT, Apache-2.0, BSD, Unlicense, CC0, SIL OFL   (notice preserved)
Study only:  GPL, AGPL, CC BY-SA and other share-alike, unknown / no license
Never:       no or unclear license · snippets without clear terms ·
             scraped recipe/ingredient lists · assets/icons/images unless
             separately licensed
```

No third-party **code** is bundled in the app. Anything reused is logged below,
every time, with enough detail to answer "where did this come from?" later.

---

## Reuse log

### `lfwdesignsystem` — LFW design-system package (same author)
- **Source:** vendored Swift Package in this repo (`lfwdesignsystem/`), synced
  *from* `a-new-word-every-day` (`e829bcc9c0dc`, package version 2.3.0) with
  `scripts/sync_designsystem.sh`; `scripts/check_designsystem_sync.sh` guards the
  copy against accidental edits.
- **Copyright:** Luke F. Walton — MIT, same as the root license
  (`lfwdesignsystem/LICENSE`).
- **What is used:** linked via XcodeGen — `LFWColors`, `LFWThemeConfig`,
  `LFWTypography`, onboarding kit, `LFWCard`, `LFWEmptyState`, `LFWCTAButtonStyle`,
  `LFWHaptics`. `App/Theme.swift` forwards to it.
- **Used as:** linked Swift Package (compiled into the app). Never edited here.

### XcodeGen — build tooling (not shipped)
- **Source:** https://github.com/yonaskolb/XcodeGen
- **License:** MIT.
- **What was used:** generates `RecipeToGroceryList.xcodeproj` from `project.yml`
  at dev time. None of its code is compiled into or shipped with the app.

### Fraunces — display typeface (bundled)
- **Source:** https://github.com/undercasetype/Fraunces (variable master, fetched
  by `scripts/fetch_fonts.sh` from the repo's `master` branch at build time; not
  committed).
- **Retrieved:** at build time; URL identical to `a-new-word-every-day`'s so both
  apps ship the same master.
- **License:** SIL Open Font License 1.1 — © The Fraunces Project Authors
  (Undercase Type).
- **What was used:** the whole variable font, registered via `UIAppFonts`.
- **Copied verbatim?** Yes (a binary font file, unmodified).
- **Notice required?** Yes — `RecipeToGroceryList/Resources/Fonts/OFL.txt` is
  bundled and the in-app Acknowledgements screen credits it. The OFL forbids
  selling the font files alone and reusing the reserved name; we do neither.
- **Used as:** bundled resource (recipe titles, ingredient headings, empty-state
  titles).

### Inter — UI typeface (bundled)
- **Source:** https://github.com/rsms/inter (variable master, fetched by
  `scripts/fetch_fonts.sh` from `master` at build time; not committed).
- **Retrieved:** at build time; same URL as the word repo.
- **License:** SIL Open Font License 1.1 — © The Inter Project Authors (Rasmus
  Andersson).
- **What was used:** the whole variable font, registered via `UIAppFonts`.
- **Copied verbatim?** Yes (a binary font file, unmodified).
- **Notice required?** Yes — `OFL.txt` bundled + Acknowledgements credit.
- **Used as:** bundled resource (rows, quantities, units, buttons, all chrome;
  numerals are always Inter).

### Seed ingredient list — `Resources/seed_ingredients.json` (own work, CC0)
- **Source:** hand-authored for this app in `scripts/seed_source.json` (the source
  of record) and assembled by `scripts/build_seed.py`, which validates the §3/§6
  invariants (unique slugs, unique canonical names, aliases unique after
  normalization, no alias equal to another item's canonical name) and fails on
  duplicates. No frequency list, no licensed dictionary, no scraped recipe site,
  no USDA/NLP dataset — the same "own the data" posture as the word app's corpus
  (`docs/prior-art-and-licensing.md`).
- **License:** dedicated to the public domain under Creative Commons CC0 1.0
  (https://creativecommons.org/publicdomain/zero/1.0/). Use it freely; no
  attribution required.
- **Copied verbatim?** N/A — original.
- **Used as:** seed data, bundled into the app and test targets.

### Jaro–Winkler string similarity — `Model/FuzzyMatch.swift` (algorithm, re-implemented)
- **Source:** the published algorithm — M. A. Jaro (1989), "Advances in record
  linkage methodology as applied to the 1985 census of Tampa, Florida", and W. E.
  Winkler (1990), "String Comparator Metrics and Enhanced Decision Rules in the
  Fellegi-Sunter Model of Record Linkage". Ported from the author's own
  implementation in `workout-logger` (`Model/FuzzyMatch.swift` at `5bffddfb80fc`).
- **License:** an algorithm, not code — not copyrightable; no third-party code
  consulted or copied.
- **What was used:** the Jaro similarity + Winkler common-prefix bonus (prefix ≤ 4,
  scaling 0.1). The symmetric token metric layered on top is original to this
  app (see `docs/learnings/003-fuzzy-thresholds.md`).
- **Copied verbatim?** No — re-implemented; attribution in the file header.
- **Notice required?** No. Credited here voluntarily (the FSRS precedent in the
  word app).
- **Used as:** resolution layer 2 (compiled into the app).

### schema.org `Recipe` vocabulary — `Import/RecipeHTMLExtractor.swift` (vocabulary implemented against, no code)
- **Source:** https://schema.org/Recipe (`recipeIngredient`, `name`,
  `recipeYield`, `@type`, `@graph`) and the JSON-LD 1.1 syntax
  (https://www.w3.org/TR/json-ld11/).
- **License:** schema.org's schema definitions are CC BY-SA 3.0; JSON-LD is a W3C
  Recommendation. Neither matters here: the app copies **no schema.org content or
  code**. It reads the property names as keys in web pages the user hands it,
  which is using a public vocabulary, not redistributing it. The JSON-LD walking
  (`@graph`, arrays, `@type` as an array, microdata fallback) is hand-written in
  Swift over `JSONSerialization`; no JSON-LD or recipe-scraping library is used.
- **Copied verbatim?** No.
- **Notice required?** No. Logged so the "no library" decision is on record.
- **Used as:** the extraction contract for the URL import path.

### Unicode vulgar-fraction table — `Model/Units.swift` and `Parsing/QuantityParser.swift` (own)
- **Source:** the fifteen code points U+00BC–U+00BE and U+2153–U+215E
  (½ ⅓ ⅔ ¼ ¾ ⅛ ⅜ ⅝ ⅞ ⅕ ⅖ ⅗ ⅘ ⅙ ⅚) and their arithmetic values, typed in by hand.
- **License:** Unicode character names and values are facts; no Unicode data
  files are bundled. The display table (`QuantityFormat.fractions`) and the
  parse table (`QuantityParser.value(ofVulgarFraction:)`) are original.
- **Copied verbatim?** No.
- **Used as:** quantity parsing and display (§7.2, §8).

---

No GPL/AGPL/share-alike/unlicensed code or data was copied. Future reuse must
add an entry here in the same format before the code lands.
