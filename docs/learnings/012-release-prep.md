# 012 — Release prep: 1.0 submitted, free, repository going public

**2026-10-27.** Recipe to Grocery List 1.0 (build 1) was archived on a Mac
and submitted to App Review at 5:52 PM Pacific (status: Waiting for Review). This entry closes the parts of gate 10 that were
owed to a human and records the one §13 decision that landed with it.

## Free

The listing was submitted at no charge, with no in-app purchases. The reasoning
in SPEC §13 held: there is no server and no ongoing cost, and the word app is
the precedent. The product page, `/apps`, and `llms.txt` on lukefwalton.com
already say "free" (`bd3a72b`), so the site and the store agree. Per the 2.3.7
rule in `docs/app-store-metadata.md`, the word does not appear in the name,
subtitle, keywords or promotional text, only in the site copy and the
description body.

## MIT

The source license followed the pricing: free app, open code, the word app's
precedent rather than the workout app's. 009 listed the files a license
touches and they landed together: root `LICENSE` (MIT), `lfwdesignsystem/LICENSE`
(same terms, by reference), `NOTICE.md`, `CONTRIBUTING.md`, `SECURITY.md` and
the README. `NSHumanReadableCopyright` was already a plain copyright line and
needed no change; MIT does not alter who holds the copyright. `CONTRIBUTING.md`
had to change in substance, not just wording: an MIT repository cannot forbid
forks or require written permission for use, so those lines became a request
(do not ship a fork under this name) and the PR policy stayed.

## Going public

The repository was private through development. `docs/publishing-source.md` is
the flip checklist (inherited from `workout-logger`). The history scan it asks
for was run before this entry: `project.local.yml` was never committed, no
ten-character team identifier appears in any revision, and
`ExportOptions.plist` is team-free by design (006/009).

## What the site does next

When Apple approves the build, `src/lib/apps.ts` on lukefwalton.com gets the
`appStore` URL for the `recipe-to-grocery-list` record, which puts the App
Store button on the product page and the hub, and the README badge here moves
from "submitted" to "on the App Store".
