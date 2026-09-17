# 007 — Photo import (gate 8)

The weakest of the three capture paths, and the spec says so up front: "Ship it,
but it does not get to drive pipeline design." It doesn't. It produces `[String]`
raw lines and hands them to the same pipeline paste and links use.

## One difference from the workout app's OCR, and it is deliberate

`workout-logger` reviews each recognized line in its own screen, carrying Vision's
per-line confidence into a low-confidence flag (`OCRCaptureModel`, `018-ocr.md`).
This app doesn't, because it already has a review screen: **Confirm is the review
step for every capture path** (§7.5). A second, OCR-only review would mean two
places to fix a misread line and two sets of rules for what "included" means.

So `TextRecognizing` returns finished lines in reading order, and the recognizer's
confidence is not surfaced. What Vision was unsure about shows up where everything
else does — as a row the user can edit before saving.

## Merging boxes into lines is the whole problem

Vision returns one observation per detected region, unordered, with the origin at
the bottom-left. Two facts make naive handling wrong:

- Several boxes usually make up one physical line. "2 cups" and "all-purpose flour"
  routinely arrive separately, so sorting alone yields half-lines.
- Sorting by `minY` misorders anything with sub-pixel jitter, and a tall box ("½")
  next to a short one ("cup cream") have different bottom edges but are obviously
  the same line.

`PhotoLineMerger` therefore sorts by **vertical centre**, groups boxes whose centres
sit within half a line-height of the running line centre, and reads each group left
to right. The line-height reference is the **median** box height, not the mean: one
oversized drop cap or chapter heading must not stretch the grouping band for the
whole page.

It is pure and Foundation-only, so it is unit-tested without Vision — which matters,
because a bad merge produces a *plausible-looking but wrong* ingredient line, the
kind of failure nobody notices in a screenshot.

## The limitation is asserted, not just documented

Two columns at the same height merge into one line. Nothing in a normalized
bounding box distinguishes a gutter from a wide space, and guessing at column
boundaries would be exactly the invention the spec forbids. So:

- the screen says "Works best on a single column of ingredients" *before* the photo
  is taken;
- `PhotoLineMergerTests` asserts the interleaving explicitly, so it stays a
  decision rather than a surprise;
- Confirm is where the user fixes it.

## Small things that matter

**Latest-request-wins.** Picking a second photo before the first finishes must not
let the older read overwrite the newer one — a monotonic generation token, checked
after every `await` (the same guard as `OCRCaptureModel`).

**The image never lands anywhere.** It is decoded in memory, recognized on device,
and dropped. The privacy screen says "Photos are read on this phone and never
stored" and that is literally all that happens. The camera permission string is the
true reason — "To read ingredients off a page" — and the path works with the camera
denied, because picking an existing photo uses the out-of-process picker and needs
no photo-library permission at all.

**Vision stays in one file.** `VisionTextRecognizer` is entirely inside
`#if canImport(Vision)`; `TextRecognizerFactory` is the only place the two worlds
meet. Its symbol names are correct-by-inspection against the workout app's
recognizer and must be verified in Xcode — the SDK is the source of truth.
