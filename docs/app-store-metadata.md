# App Store metadata — Recipe to Grocery List

Compliant copy for App Store Connect, in the shape of
`a-new-word-every-day/docs/app-store-metadata.md` (`e829bcc9c0dc`). **Do not use
"Free", "$0", or other price language in the name, subtitle, or promotional
text** — Apple Guideline 2.3.7 (the word app was rejected for exactly this in
July 2026). Price belongs in the description body only, and only once the
free-vs-paid decision is made (SPEC §13).

## Name

**Use:** `Recipe to Grocery List` (23 chars) — descriptive, matches the repo and
`CFBundleDisplayName`. **Availability must be checked in App Store Connect**
before submission; the name is reserved when the app record is created. If
taken, keep the display name and pick a listing name from the same words
("Recipe → Grocery List" is not allowed — no symbols).

## Subtitle (≤30 chars)

**Use:** `Recipes in, one list out.`

Alternates:
- `Paste a recipe. Shop the list.`
- `Private. No account.`
- `Nothing leaves your phone.`
- `One grocery list, any recipe`

**Never:** anything with `Free`, `$`, `no cost`, `no subscription` (price words —
Guideline 2.3.7).

## Promotional text (≤170 chars, optional)

```
Share a link, paste a recipe, or photograph a page. Confirm the ingredients, pick what you're cooking, and shop from one merged list. Private. No account. No cloud AI.
```

## Description (full body — paste into App Store Connect)

No URLs in the description — Support and Privacy URLs go in their own fields.

```
Recipe to Grocery List turns the recipes you're actually cooking this week into one grocery list you can check off in the store.

THREE WAYS IN, ONE LIST OUT
• Share a recipe link from Safari, or paste it
• Paste the ingredient list from anywhere
• Photograph a cookbook page and let the app read it
Every path lands on the same Confirm screen: quantity, unit, name and note for each line, matched to a pantry item. Fix what's wrong, tap Save.

YOUR LIST, MERGED
Pick any saved recipes as "cooking this" and get a single list grouped by aisle — produce, bakery, dairy, meat, seafood, frozen, pantry, other. Two recipes that both need garlic show one heading with both lines under it. Amounts are added up only when the units match; the app never converts or guesses a number. Check off an ingredient once and it stays checked while you add or remove recipes. Add the odd extra ("also coffee") by hand. Done shopping clears it in one tap.

HONEST PARSING
Every line you give the app is kept exactly as written. Lines it can't place are shown, never dropped — you decide whether to create an ingredient, match it to one you already have, or keep it as plain text.

PRIVATE. NO ACCOUNT.
No login, no server, no analytics, no ads, no third-party code. Recipes, ingredients and your list live on your iPhone. When you give it a link, the app downloads that page, once, and nothing else. On iPhones with Apple Intelligence the parse is refined on-device; there is no cloud AI, and the app works fully without it.

Built for people who cook from recipes and shop from a list, and want nothing more than that.
```

Add a pricing sentence to the body **only** once SPEC §13 is decided (e.g. the
word app's "Open source (MIT)" line has no analogue here until the license is
chosen).

## Keywords (≤100 chars, comma-separated, no spaces after commas)

Apple already indexes the **name** and **subtitle** — don't spend characters on
`recipe`, `grocery` or `list`.

**Use:**
```
shopping,ingredients,meal,cooking,pantry,checklist,import,share,offline,private,cookbook,dinner
```

## Review notes (paste into App Review)

The full version is `docs/app-store-review-notes.md`; this is the short block.

```
No account, no login, no demo credentials. Launch and use immediately.

The app makes exactly one kind of network request: when the user gives it a recipe link, it downloads that page once (https only) and nothing else. Pasting text and photographing a page make no request at all. There is no server of ours, no analytics, no third-party SDK.

Everything works with the camera denied and on devices without Apple Intelligence: the parser is deterministic first; Apple's on-device Foundation Models only refine the result where available. There is no cloud AI.

Smoke test: Add tab → Paste → paste a few ingredient lines (e.g. "2 cups flour", "3 cloves garlic, minced", "1 tsp salt") → Confirm → Save. Recipes tab → toggle "cooking this". List tab → grouped list; tap a heading to check it; "Done shopping" clears.

Share Extension: in Safari, Share → Recipe to Grocery List → "Added." → open the app; the Confirm screen appears.

App Privacy: Data Not Collected. Camera/photo permission is requested only when the Photo path is chosen.
```

## URLs

| Field | URL |
|-------|-----|
| Support | https://lukefwalton.com/recipe-to-grocery-list/ |
| Privacy | https://lukefwalton.com/recipe-to-grocery-list/privacy/ (mirrors `docs/privacy.md`) |

Both pages are **planned**; publish them before submitting (the privacy URL must
resolve for review).

## App Privacy

**Data Not Collected.** Matches the bundled `PrivacyInfo.xcprivacy` (no tracking,
no collected data types, UserDefaults `CA92.1` as the only required-reason API)
and `docs/privacy.md`.

## Category

Primary: **Food & Drink** (`LSApplicationCategoryType` =
`public.app-category.food-and-drink`). Secondary: Utilities.

## Screenshots

`bash scripts/capture_app_store_screenshots.sh` → `build/app-store-screenshots/iphone/`
(6.5", 1284×2778): `01-list`, `02-recipes`, `03-add`. iPhone only; no iPad set
(`TARGETED_DEVICE_FAMILY 1`).

## 1.0 submission checklist

Decisions first (SPEC §13 — these gate the listing, not the code):

- [ ] **Decide free vs paid** (§13). Free has no server cost and the word app's
      precedent; paid up front is the workout app's. Either is fine; write the
      reason in a `docs/learnings/` entry.
- [ ] **Decide the source license** (§13), tied to the pricing decision. Add the
      root `LICENSE`, update `NOTICE.md`, `CONTRIBUTING.md`, `SECURITY.md`,
      `lfwdesignsystem/LICENSE`, `NSHumanReadableCopyright` and the README's
      License section in the same PR.
- [ ] **Check the name is available** in App Store Connect.

Local prep:

- [ ] **Replace the placeholder app icon.** `AppIcon-1024.png` is a generated
      forest-green square with a gold disc (see
      `docs/learnings/001-scaffold-and-inheritance.md`). Ship real artwork.
- [ ] `bash scripts/fetch_fonts.sh && bash scripts/run_tests.sh` green on a Mac
      (the branch was authored without a Swift toolchain — this is the first
      real verification).
- [ ] Manual QA on a device **without** Apple Intelligence and with the camera
      denied (gate 9); record it in `docs/learnings/008-non-ai-path.md`.
- [ ] Release archive **1.0 (1)** → `bash scripts/release.sh` (or
      `scripts/archive_for_testflight.sh`) → `build/RecipeToGroceryList.xcarchive`.
- [ ] Screenshots captured (above); look at them — the demo seed must not show
      anything copyrighted.
- [ ] `NOTICE.md` audit: every bundled thing has an entry; `OFL.txt` is in the
      bundle; Acknowledgements screen lists Fraunces, Inter, the CC0 seed, the
      design system.
- [ ] Publish the Support and Privacy pages.

App Store Connect + Xcode:

1. **App record** — name, subtitle (above), Food & Drink, no price words.
2. **Upload** — Xcode → Organizer → Distribute App → App Store Connect (build **1**).
3. **App Privacy** — Data Not Collected.
4. **Review notes** — paste the block above.
5. **Age rating** — 4+.
6. **Submit** — Add for Review.
