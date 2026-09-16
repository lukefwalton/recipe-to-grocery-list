# App Store Review Notes — Recipe to Grocery List

**Status:** v1.0 submission prep (build 1). Shape inherited from
`workout-logger/docs/app-store-review-notes.md` (`5bffddfb80fc`). Keep these
notes for future updates; paste the short block from
`docs/app-store-metadata.md` into App Store Connect → App Review Information →
Notes when submitting, and use this page as the long form.

These notes explain the privacy-first design so the reviewer can exercise the
whole app without friction.

## No account — no demo credentials needed

Recipe to Grocery List has **no account system, no sign-in, and no server.**
There is nothing to log into; there are no demo credentials. Launch the app and
use it immediately.

## Exactly one kind of network request

The privacy policy states it in one sentence, and it is the whole truth: "When
you give it a link, the app downloads that page, once, and nothing else."
Specifically: a single `https` GET of the exact URL (plain `http`
is refused), at most five same-scheme redirects, no cookies, no JavaScript, no
images or sub-resources, a 15 s timeout and a 3 MB cap, no retry without a tap.
The page is parsed once for its schema.org `Recipe` ingredient list and
discarded. Pasting text and photographing a page make **no** network request.
There are no analytics, no crash reporting, and no third-party SDKs, so there is
no other traffic to explain.

## Everything works with all permissions denied

The app is fully functional with the camera denied and on a device without
Apple Intelligence:

- **Parsing is deterministic-first.** Every ingredient line goes through a
  regex splitter (quantity, unit, name, note) and a layered matcher (exact →
  alias → loose → fuzzy → on-device embeddings). This path needs no AI and no
  network.
- **Apple Intelligence is an optional refinement.** On iOS 26 devices where the
  system model is available, the app makes one on-device request per recipe to
  tidy the parse. Without it, a few more rows say "New ingredient" and need a
  tap; the copy says so. No cloud fallback exists.
- **Camera is opt-in and in context.** The Photo path offers the photo picker
  (no permission needed — out-of-process picker) and a camera button that
  requests permission when tapped. With the camera denied, the picker still
  works and the Link and Paste paths are unaffected.
- **Notifications, location, contacts, health:** none used.

Suggested smoke test on a clean install:

1. First launch → two onboarding pages → Continue.
2. **Add** tab → **Paste** → paste a few lines, e.g.
   `2 cups flour` / `3 cloves garlic, minced` / `1 tsp salt` / `a splash of something`
   → **Continue**. The Confirm screen shows one row per line; the last line is
   marked *New ingredient* (tap **Keep as text**). Enter a title → **Save**.
3. **Recipes** tab → the recipe appears with a "cooking this" toggle → turn it on.
4. **List** tab → the list appears grouped by aisle (flour under Pantry, garlic
   under Produce, the kept-as-text line under Other). Tap a heading to check it;
   it sinks to the bottom of its section.
5. Add a second recipe that also uses garlic → both lines appear under one
   *Garlic* heading, with a summed count when the units match.
6. **Done shopping** → confirm → the list clears and every recipe is deselected.
7. (Optional, needs network) **Add** → **Link** → paste a recipe page URL →
   the ingredients are extracted from the page's JSON-LD and land on the same
   Confirm screen. Paste an `http://` link → refused with a clear message.
8. (Optional) In Safari, Share → *Recipe to Grocery List* → "Added. Open Recipe
   to Grocery List to finish." → open the app → the Confirm flow opens.

## Data: not collected

Recipe to Grocery List collects, transmits, and sells **nothing** — no
analytics, no ads, no third-party SDKs, no tracking, no IDFA, no ATT prompt. All
data is stored in a private on-device SQLite database in the app's sandbox. This
matches the **App Privacy: Data Not Collected** label and the bundled
`PrivacyInfo.xcprivacy`.

- Privacy policy: hosted at `https://lukefwalton.com/recipe-to-grocery-list/privacy/`
  (source: `docs/privacy.md`).
- Required-reason API: **UserDefaults** only (`CA92.1`, app-functionality
  persistence of theme and the onboarding flag).
- App Group (`group.com.lukewalton.recipetogrocerylist`): used solely for the
  Share Extension's inbox file. The extension never opens the database.

## Camera (5.1.1)

- Purpose string: "To read ingredients off a page. The photo is processed on this
  phone and never stored or uploaded." That is exactly what happens: the image is
  recognized in memory with Vision and released; no image is written to disk or
  to the photo library.
- Requested only when the user taps the camera button in the Photo path.

## Not medical or nutritional advice

The app makes no nutrition, calorie, dietary or health claims and stores no
nutrition data (an explicit non-goal). It lists what recipes ask for; it does
not tell anyone what to eat.

## Share Extension

The extension (`com.lukewalton.recipetogrocerylist.share`) accepts one web URL or
plain text from the share sheet, appends it to the App Group inbox, and shows
"Added. Open Recipe to Grocery List to finish." It performs no parsing and no
networking; the host app does all the work when it next comes to the foreground.
