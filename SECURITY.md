# Security Policy

Recipe to Grocery List is a local-first iOS app. On-device SQLite is the single
source of truth — there is **no server, no account, and no tracking**, and the
app makes no network calls to a backend of its own. It makes exactly one kind of
network request — the privacy policy's sentence is the whole of it: when you give
it a link, the app downloads that page, once, and nothing else
(`Import/RecipeFetchPolicy.swift`: https only, one GET, at most five
same-scheme redirects, no cookies, 15 s timeout, 3 MB cap). Optional features stay
on device: **on-device OCR** (Vision) for photographed pages and an **on-device
Foundation Models** refinement of the parse. The Share Extension writes a link or
pasted text into a small App Group inbox file and does nothing else. That removes
whole classes of vulnerability — but the app, the extension, the fetcher, and the
build/release scripts can still have bugs worth reporting privately.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Instead:

1. Email **[luke@lukefwalton.com](mailto:luke@lukefwalton.com)** with a
   description of the issue.
2. Include steps to reproduce, the affected area (app, Share Extension, URL
   fetch, OCR, parsing, or a script), and the potential impact.
3. You'll get an acknowledgement within a few days. Please allow a reasonable
   window to ship a fix before disclosing publicly.

## In scope

- Any path that causes the app to make an unexpected network request — anything
  beyond the single page fetch of the exact URL the user gave (sub-resources,
  retries without a tap, a non-https redirect being followed, a request from the
  extension), or that sends recipe or list data off the device
- On-device data exposure through the App Group inbox (`inbox.json`): another
  process reading or planting items, or the app acting on inbox content beyond
  opening the Confirm flow for it
- The Share Extension doing anything other than appending to the inbox
  (parsing, networking, opening the database)
- Malicious page content reaching further than the extractor should allow (the
  HTML is parsed once for JSON-LD / microdata ingredient lines and discarded;
  no JavaScript runs, no page is stored)
- Issues in the build/release scripts (`scripts/`) that could compromise a
  release archive, leak signing material, or fetch a font from the wrong place

## Not a security issue

- Feature requests, visual/UI bugs, or parser mistakes (a wrong quantity, a
  missed ingredient) with no security impact — file those as
  [issues](https://github.com/lukefwalton/recipe-to-grocery-list/issues).
- Reminder: this repo's source license is still to be decided
  ([docs/SPEC.md §13](docs/SPEC.md#13-open-decisions)) — treat it as
  all-rights-reserved public source. Security reports are welcome regardless.

## Supported versions

Fixes target the latest App Store release and the `main` branch. Older builds
are not separately patched.
