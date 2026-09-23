# Prior art & licensing — don't reinvent the wheel (but own the data)

Where this app reuses existing, well-solved work, and the license of each
choice. The guiding rule for **application code** is **permissive only**
(MIT / Apache / BSD / ISC / public-domain / CC0 / SIL OFL), inherited from
`a-new-word-every-day/docs/prior-art-and-licensing.md` (`e829bcc9c0dc`) together
with its conclusion: *the cleanest way to avoid every license question is to own
the data.* The second rule is the family's **port, don't depend**: a small
published algorithm is re-implemented with attribution rather than vendored as a
package, so the app ships with zero third-party dependencies and the privacy
claim stays auditable.

License notes below were checked against the projects' own LICENSE files and
license pages when this document was written (September 2026). Re-verify before
vendoring anything.

---

## 1. The ingredient seed (the data)

**Decision: hand-authored, dedicated to the public domain (CC0).**

`scripts/seed_source.json` is the source of record — a few hundred common
grocery items, each with a stable slug, a canonical name, a store category and
curated aliases (`vegetable broth` ← `veggie broth`, `vegetable stock`;
`scallion` ← `green onion`, `spring onion`). `scripts/build_seed.py` validates
the invariants (unique slugs, unique canonical names, aliases unique *after*
§7.1 normalization, no alias equal to another item's canonical name) and writes
`RecipeToGroceryList/Resources/seed_ingredients.json`. No external data of any
kind went in; no attribution is required of anyone. Logged in `NOTICE.md`.

Why not use an existing food vocabulary:

| Source | Contains | License | Verdict |
|---|---|---|---|
| **USDA FoodData Central** | ~400k foods with nutrient profiles | Public domain / CC0 (US Government work) | ❌ Permissive but the wrong shape: it is a *nutrition* database (a §2 non-goal), item names are lab-style ("Onions, raw"), and it has no grocery aliases. A hand list is smaller, cleaner and ours. |
| **Open Food Facts** | Packaged products, brands, ingredients | **ODbL 1.0** (share-alike database license) | ❌ Copyleft on the *database*; a derived seed would carry ODbL obligations. Avoid. |
| **FoodOn** ontology | Formal food ontology (~30k terms) | CC BY 4.0 | ❌ Attribution is fine, altitude is not — an ontology of food *kinds*, not what shoppers write on lists. |
| **Wikidata** food items | Names, aliases, categories | CC0 | ❌ License is fine; we still chose to own the data rather than inherit a scraped subset whose provenance would need explaining forever. |
| Recipe-site ingredient dumps | Ingredient strings scraped from recipe pages | No license / site terms | ❌ **Never.** Scraped recipe content is exactly the thing the copy rule forbids. |
| Licensed dictionaries / cookbooks | Ingredient glossaries | Copyright | ❌ **Never.** |

The user's own additions (`is_custom = 1`) and *Same as…* aliases are their data,
in their database, and never leave the phone.

---

## 2. String similarity — Jaro–Winkler (algorithm, re-implemented)

**Decision: re-implement; attribute in the file and in `NOTICE.md`.**

`Model/FuzzyMatch.swift` implements Jaro (1989) with the Winkler (1990) prefix
bonus, ported from the author's own implementation in
`workout-logger/Model/FuzzyMatch.swift` (`5bffddfb80fc`). An algorithm is not
copyrightable; no third-party code was consulted or copied. The token metric on
top of it is **symmetric** here (minimum of both directions) rather than the
workout app's one-directional average, because food names have substring traps
(`cream` vs `sour cream`, `paprika` vs `smoked paprika`) that a one-sided average
scores as perfect matches — see `docs/learnings/003-fuzzy-thresholds.md`.

Considered and not used: Swift string-metric packages on GitHub (various MIT).
Copyable, but a 40-line algorithm is not worth a dependency, and the threshold
work (calibrated on the golden corpus) is the real effort anyway.

---

## 3. Fraction and quantity parsing (own)

**Decision: own code, tested against the golden corpus.**

`Parsing/QuantityParser.swift` accepts integers, decimals, ASCII fractions
(`1/2`, `1 1/2`, `1-1/2`), Unicode vulgar fractions (`½`, `1½`), ranges
(`2-3`, `2 to 3`, `2–3`), number words (`one`…`twelve`) and `a`/`an` before a
unit. The vulgar-fraction table is nine code points and their values, typed in
by hand (`QuantityParser.value(ofVulgarFraction:)` for parsing,
`QuantityFormat.fractions` in `Model/Units.swift` for display). No Unicode data
file is bundled; character values are facts. The unit table (`UnitTable`) is the
spec's §8 list plus what the corpus needed, all our own.

---

## 4. schema.org `Recipe` and JSON-LD (a vocabulary we implement against, not code we copy)

**Decision: implement the walk in Swift over `JSONSerialization`; use no library.**

The URL import path reads `<script type="application/ld+json">` blocks, walks
objects / arrays / `@graph`, finds a node whose `@type` is `Recipe` (string or
array, `schema:Recipe` and URL-suffixed forms tolerated) and takes
`recipeIngredient`, `name` and `recipeYield`; then falls back to microdata
(`itemprop="recipeIngredient"`). schema.org's schema definitions are CC BY-SA
3.0 and JSON-LD is a W3C Recommendation, and neither obligation attaches: the
app redistributes no schema.org text or code — it reads property names as keys
in pages the user hands it. `Import/RecipeHTMLExtractor.swift` is ~200 lines and
fixture-tested offline against hand-written HTML (invented recipes; no scraped
pages in the repo).

Considered and not used:

| Project | What | License | Why not |
|---|---|---|---|
| **hhursev/recipe-scrapers** | Python, per-site scrapers + schema.org fallback | MIT | Python, so unusable in-process anyway; more importantly it is a *scraping* library with hundreds of site-specific rules to maintain. The schema.org path alone covers the sites that publish structured data, which is the only path a privacy-first app can defend. |
| **schema-dts / any JSON-LD processor** | Full JSON-LD expansion / framing | Apache-2.0 / MIT / W3C | Expansion, contexts and remote `@context` fetching are exactly what we must *not* do (one request, no sub-resources). A recursive walk for one `@type` is enough. |
| SwiftSoup (HTML parser) | Full HTML DOM parsing | MIT | Copyable, but a dependency for one `itemprop` fallback is disproportionate; a tolerant scan over `itemprop="recipeIngredient"` elements plus tag stripping does the job and stays dependency-free. |

---

## 5. HTML entity decoding (own)

**Decision: a small table plus numeric forms, in `Import/HTMLEntities.swift`.**

Ingredient strings in JSON-LD and microdata carry `&amp;`, `&frac12;`, `&deg;`,
`&#189;`, `&#x2013;`. The decoder handles the named entities that occur in
recipe text (`amp lt gt quot apos nbsp deg frac12 frac14 frac34 ndash mdash
hellip rsquo lsquo rdquo ldquo`) and all numeric/hex references, then strips
tags and collapses whitespace. The full HTML5 entity table (2,231 names) is a
WHATWG document under the W3C/WHATWG licenses and would be copyable, but it is
not needed: an unknown named entity is left as-is and shows up verbatim in
Confirm, where the user sees it. `NSAttributedString`'s HTML importer was
rejected because it runs WebKit machinery for what is a string-table problem.

---

## 6. Ingredient-line parsing models (deliberately not used)

**Decision: regex splitter (always) + Apple's on-device Foundation Models (when
available). No bundled ML model, no cloud API.**

| Project | What | License | Why not |
|---|---|---|---|
| **NYT ingredient-phrase-tagger** | CRF model tagging quantity/unit/name/comment; trained on NYT Cooking data | Apache-2.0 (code); training data derived from NYT recipes | A Python/CRF++ toolchain and a model whose training data provenance we would have to explain; the app is Swift and offline. |
| **strangetom/ingredient-parser** | Python CRF parser, actively maintained | MIT | Same: Python, a bundled model, a training-data question. Apple's system model does this job on-device with nothing shipped in the bundle. |
| **Zestful, Spoonacular, Edamam** | Ingredient-parsing / recipe APIs | Commercial, network | ❌ Every one of them would send the user's recipe to a server — the one thing the privacy promise rules out. |
| **Core ML conversion of any of the above** | On-device inference | Depends | Ships a model with inherited provenance for marginal gain over regex + Foundation Models; the deterministic path already has to be good enough for devices without Apple Intelligence (§7.6). |

The consequence is written into the product: the splitter runs everywhere, the
LLM only refines, and both are measured against the same golden corpus
(`RecipeToGroceryListTests/Fixtures/ingredient_lines.json`) whose lines are
hand-written in the shapes real pastes, JSON-LD and OCR produce — not copied
from any site.

---

## 7. Fonts (variable, OFL 1.1 — app-store-safe)

Both **SIL Open Font License 1.1**. OFL is *not* problematic copyleft for app
embedding: you may bundle the `.ttf` in a binary freely; you may **not** sell the
font files alone or reuse the reserved font names. We ship `OFL.txt` + an
Acknowledgements credit, and fetch rather than commit the binaries
(`scripts/fetch_fonts.sh`).

| Font | Role | Repo |
|---|---|---|
| **Fraunces** | Display — recipe titles, ingredient headings, empty-state titles | `undercasetype/Fraunces` |
| **Inter** | UI — rows, quantities, units, buttons, chrome; all numerals | `rsms/inter` |

The other five faces the design system knows (Literata, Newsreader, Source
Serif 4, Source Sans 3, Recursive) are not bundled and not offered in the picker
(`Theme.bundledTypefaces`), because an unbundled face renders as a silent system
fallback.

---

## 8. Everything else is inherited from the same author

Storage (`SQLiteDB`, migrations, one write path, the boundary guard), the
Foundation Models adapter shape, the Vision OCR wrapper, the contextual-embedding
matcher and the CI workflows come from `workout-logger` (`5bffddfb80fc`); the
design system, theming, fonts tooling, release scripts and this document's
posture come from `a-new-word-every-day` (`e829bcc9c0dc`). Same copyright
holder, no license question — see `docs/learnings/001-scaffold-and-inheritance.md`
for the file-by-file list. XcodeGen (MIT) generates the project at dev time and
ships nothing.

---

## Sources

**Food data**
- USDA FoodData Central: https://fdc.nal.usda.gov/ (public domain / CC0 statement on the site)
- Open Food Facts (ODbL): https://world.openfoodfacts.org/terms-of-use
- FoodOn (CC BY 4.0): https://foodon.org/
- Wikidata (CC0): https://www.wikidata.org/wiki/Wikidata:Licensing

**Algorithms**
- Jaro (1989), Winkler (1990) — see `NOTICE.md` for the full citations
- Unicode vulgar fractions: https://www.unicode.org/charts/PDF/U0080.pdf, https://www.unicode.org/charts/PDF/U2150.pdf

**Structured recipe data**
- schema.org Recipe: https://schema.org/Recipe · license: https://schema.org/docs/terms.html
- JSON-LD 1.1: https://www.w3.org/TR/json-ld11/
- hhursev/recipe-scrapers (MIT): https://github.com/hhursev/recipe-scrapers
- SwiftSoup (MIT): https://github.com/scinfu/SwiftSoup

**Ingredient parsing**
- NYT ingredient-phrase-tagger (Apache-2.0): https://github.com/nytimes/ingredient-phrase-tagger
- strangetom/ingredient-parser (MIT): https://github.com/strangetom/ingredient-parser
- HTML entity table (WHATWG): https://html.spec.whatwg.org/multipage/named-characters.html

**Fonts**
- Fraunces: https://github.com/undercasetype/Fraunces · Inter: https://github.com/rsms/inter
- SIL OFL 1.1: https://openfontlicense.org/
