# 009 — App Store readiness (gate 10)

Gate 10 is the one gate that is mostly not code. It is a privacy manifest per
bundle, a listing that doesn't get rejected, screenshots that don't leak someone
else's recipe, an attribution file that is actually true, and an archive. This
records the decisions and what is still owed.

## Two bundles, two privacy manifests, and the empty array is the interesting one

The App Store validates a privacy manifest per shipped bundle at upload, so the
Share Extension carries its own rather than inheriting the app's. Both declare
`NSPrivacyTracking` false, no collected data types, and no tracking domains,
which is the literal truth: nothing is collected, so App Privacy is **Data Not
Collected**.

The difference between them is the required-reason API list, and it is a
deliberate claim rather than an oversight:

| bundle | `NSPrivacyAccessedAPITypes` | why |
|---|---|---|
| app | `UserDefaults` / `CA92.1` | `SettingsStore` persists the theme and the onboarding flag |
| extension | **empty** | it writes one JSON file into the App Group container and touches nothing on Apple's list |

The extension's empty array is worth stating out loud because the obvious guess
is wrong: sharing state through an App Group usually means *shared*
`UserDefaults`, which is `1C8F.1`. This app's inbox is a plain file
(`ShareInbox`), so there is no `UserDefaults` access to declare on that side at
all. SQLite and `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
are not on the required-reason list either. If the inbox ever moves to shared
defaults, that entry has to appear — the boundary guard
(`scripts/check_store_boundary.sh`) won't catch it, because shared defaults
aren't the store.

## The listing rule that already cost this family a rejection

`a-new-word-every-day` was rejected in July 2026 under **Guideline 2.3.7** for
price language in metadata. So `docs/app-store-metadata.md` carries the rule in
bold at the top: no "Free", no "$", no "no subscription" in the name, subtitle,
keywords or promotional text. Price, if it is ever mentioned, goes in the
description body and nowhere else.

That constraint shapes the copy more than it looks. The strongest thing this app
can say about itself is a privacy claim, not a price claim, and the subtitle
field is 30 characters: `Recipes in, one list out.` The privacy sentences live
in the description body, where they are allowed to be sentences.

One deliberate consistency: the network sentence in the listing, the privacy
page, `docs/privacy.md`, the onboarding, the in-app privacy screen and the
review notes are the **same sentence**, and it is the one `RecipeFetchPolicy`
implements clause by clause (`006`). A reviewer who compares the listing to the
behaviour finds them identical, because they were written from the same source.

## Screenshots seed through the real write path

`scripts/capture_app_store_screenshots.sh` takes three shots — the three tabs —
at 6.5" (1284×2778), iPhone only, because `TARGETED_DEVICE_FAMILY` is 1 and
there is no iPad build to screenshot.

The demo state comes from `ScreenshotDemoSeeder`, which writes two recipes and a
list **through `RecipeStore`'s normal save path**, not a fixture database. A
screenshot seeded by hand-written rows can show a state the app cannot actually
produce; this one cannot. It is gated on a `-ScreenshotDemo` launch argument in
DEBUG only, alongside `-UITestSkipOnboarding` and the `-OpenTab…` arguments, so
none of it exists in a Release build.

The recipes in it are written for this repo. That is not fussiness: a screenshot
is published artwork, and a cookbook page photographed for a demo is someone
else's copyrighted text on Apple's servers. The checklist item says *look at
them* for that reason.

## NOTICE.md is an audit, not a formality

Every bundled thing has an entry, including the three that people usually skip:

- the two **OFL** typefaces, whose license requires the notice to travel with
  the binary — so `OFL.txt` is a bundled resource and the Acknowledgements
  screen credits both faces, not just the docs;
- the **seed ingredient list**, which is original work and explicitly CC0, which
  is the whole reason it could be written at all: no scraped site, no licensed
  food dictionary, no USDA extract (`002`);
- two things that are *not* third-party code but are logged anyway —
  Jaro–Winkler (a published algorithm, re-implemented) and the schema.org
  `Recipe` vocabulary (property names read out of pages the user supplies, with
  no library vendored and no schema content redistributed).

No GPL, AGPL or share-alike code or data is present. The copy rule that produced
that state is written down in the same file, so the next person adding a
dependency has the test in front of them.

## What gates the submission that is not code

Two SPEC §13 decisions, and neither is mine to make:

1. **Free vs paid.** Both siblings are precedents in opposite directions. It
   changes one sentence of the description and nothing else.
2. **The source license.** There is deliberately no root `LICENSE`; `NOTICE.md`
   says so plainly and says why the code is public anyway (so the privacy claims
   can be audited). It is tied to the pricing decision, and when it lands it
   touches `LICENSE`, `NOTICE.md`, `CONTRIBUTING.md`, `SECURITY.md`,
   `lfwdesignsystem/LICENSE`, `NSHumanReadableCopyright` and the README together
   — a half-applied license is worse than none.

Leaving both open is a real answer, not a deferral: nothing in the code depends
on either, and guessing would put a wrong license on someone else's repository.

## The archive, and what is still owed

`scripts/archive_for_testflight.sh` fetches fonts **first**, then regenerates the
project, then archives Release to `build/RecipeToGroceryList.xcarchive`. The font
fetch is not incidental. The typefaces are gitignored and downloaded at build
time, so an archive produced without them ships system fonts and looks subtly
wrong in a way nobody notices until it is on TestFlight.

Still owed, all of it requiring a Mac, a device or an Apple ID:

- [ ] `bash scripts/fetch_fonts.sh && bash scripts/generate.sh && bash
      scripts/run_tests.sh` — the first real compile of this branch (`001`).
- [ ] Real app-icon artwork; `AppIcon-1024.png` is a generated placeholder.
- [ ] Gate 9 device QA, recorded in `008`.
- [ ] Name availability checked in App Store Connect.
- [ ] Support and Privacy pages published — the privacy URL must resolve before
      review.
- [ ] Archive 1.0 (1), upload, App Privacy → Data Not Collected, age rating 4+,
      review notes pasted from `docs/app-store-metadata.md`.

The checklist lives in `docs/app-store-metadata.md`; this file is where the
result and any rejection go.
