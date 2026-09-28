# 011 — The first read-through, and what it moved

`010` recorded a method: check structurally what a compiler would check, because no
toolchain exists where this was written. This entry records the next pass — a
line-by-line read of every layer against SPEC and STANDARDS, by area, with the
Python mirrors standing in for the parts that can be executed. It found one
build break, a handful of tests that disagreed with the code they were written
for, and a short list of behaviours that were wrong in ways a user would meet in
the first week. Everything below landed in the same change; the last section is
what was found and deliberately *not* changed.

## What would have failed the first build

- `RecipeHTMLExtractorTests`: one `fixture(_:)` call outside `XCTUnwrap` had no
  `try`. The whole test bundle would not compile.
- `RecipeStoreTests` mutated a captured `var` inside a `DispatchQueue` closure
  from a `@MainActor` class. Most likely a warning under Swift 5, an error under
  Swift 6; a lock-guarded counter removes the question.
- `AppModel.init` called a static method through `Self` before its stored
  properties were set; spelled by type name now. `RecipePipelineTests` called a
  static helper unqualified from an instance-property initializer, the one file
  that did (the others qualify it).

## Tests that disagreed with the code

Four tests asserted values the code never produced: `file://` reading as
"invalid" rather than "not https" (the host check ran before the scheme check),
`stripTags` gluing text across a removed `<script>` block, `unwrapCDATA` keeping
the newlines around the JSON, and a Confirm edit test validating a draft that
still had undecided rows. In every case the code moved to the test's reading,
except the last, where the test now decides its rows first.

## Behaviour a user would have met

- **A share made while the app was closed was not opened on launch.** `AppRoot`
  mounts after the async bootstrap, by which time the scene is already `.active`,
  so `onChange(of: scenePhase)` never fired. `initial: true`.
- **A second share could overwrite the first**, and a share arriving mid-Confirm
  replaced the navigation path and threw the draft away. `drainInbox` now leaves
  the file alone while an item is unconsumed, and `AddView` waits for the Confirm
  stack to unwind. Manual Link/Paste taps also start with an empty field instead
  of the last shared value.
- **Leaving the Link screen mid-download left it stuck on "Downloading…"** with
  Fetch disabled; the phase is reset on disappear, and cancelling the Swift task
  now cancels the URLSession task too, which the comment always claimed.
- **Swipe-to-delete removed the row before the confirmation.** A `.destructive`
  swipe button animates its row out on tap; the role is gone, the tint stays.
- **"a large onion, diced" fuzzy-matched Red onion.** An article only reads as
  a quantity before a unit, so it was still in front of the size word; the
  splitter now looks past it. Three corpus rows pin the shape.
- **"to taste" fuzzy-matched Tomato paste (0.87) and Save accepted it.** The
  splitter marks such a line unresolved (nothing left for a name), but the
  resolver ignored the flag. Layers 0–3 no longer run on an unresolved line;
  only the model's guess can propose an ingredient for it.
- **"1,000 g" and "1 /2 cup" both parsed as quantity 1.** A comma before a digit
  and whitespace before a fraction slash are no longer number boundaries, and a
  digit-glued comma is no longer a note separator. Both lines now keep their
  quantity empty and their text whole — no number beats a wrong one.
- **Opening Edit and tapping Done rounded an untouched quantity** (3.14 → 3.1)
  by re-parsing the display string. Only a changed field is written back.
- **A pasted absurd number crashed Confirm.** `Int(_:)` traps past 2^63; values
  past 1e15 format with `%.0f`.
- **Same as… onto an ingredient created in this recipe taught nothing.** The
  alias plumbing already supported pending targets end to end (`PendingAlias`,
  the validator, `save`); only `choosePending` skipped it. It now queues the
  alias under the same conflict rule as `choose`, with a test.
- **A row the user decided still carried the model's warning dot** when the
  model had said "medium", and a low-confidence deterministic hit was shown as
  plain resolved while a medium one was highlighted. `DraftRow.state` now treats
  a user decision as resolved and any confidence below high as highlighted. The
  §7.5 table says so; a deterministic hit is still never demoted to *New*.
- Smaller: a refused redirect's 3xx could be re-reported as "error (301)"; the
  context menu on a kept-as-text row taught an alias from one entry point and not
  the other; the Done shopping confirmation did not mention the checked manual
  items it deletes; a reseed could overwrite the category a user chose for a
  custom ingredient that a later seed happens to share a slug with.

## Docs that described a different app

The share flow lands on the Link or Paste screen with the item filled in; the
link is fetched only on a tap. SPEC §5.1, privacy.md, SECURITY.md, the review
notes and the metadata all said "opens Confirm". They say what the code does
now, and the reason is the better one: the single network request stays behind a
tap even when the link arrived by share. Also corrected: the inbox JSON shape,
the manifest's required-reason API, the corpus fixture path, a stale
normalization follow-up in `002`, and the vulgar-fraction count in NOTICE.

## Guards that had holes

`check_schema.py` read only the first `case` line of each enum, so a case added
on its own line passed the CHECK comparison — the exact mistake the guard exists
for. It walks the enum body now, and a mutation test proved it. `check_sources.py`
counted any `.init(` call as a declared initializer and treated `private let x =
…` as a memberwise parameter; both fixed, and an `init` in an extension counts.
`build_seed.py` skipped its version check silently when the regex missed. The
Python mirrors' own self-tests now run in `checks.yml`: the seed is built through
one and the corpus is calibrated through the other, so a mirror that drifts from
the Swift miscalibrates both without anyone noticing. On a Mac: `setup_signing.sh`
exited silently with no certificate, the screenshot script only knew iPhone 14–16
simulator names, and `check_fonts_sync.sh` crashed on bash 3.2 in its own failure
path.

## Found, and left alone — the owner's call

- **Fuzzy false positives outside the corpus.** Against the real seed, via the
  mirror: pepperoni → Black pepper (0.938, above the 0.93 bar so layer 3 never
  runs), whipped cream → Heavy cream, grapefruit → Grape, caraway seeds →
  Cardamom, coconut flour → Cornstarch, salami → Salsa. Two holes: the
  Jaro–Winkler prefix bonus on single-word pairs, and the head-noun cap at 1.0
  when last words match. `003`'s "0 wrong matches" holds on the in-repo corpus
  only. Adding these as negative rows would take the resolution rate below the
  baseline, so they are recorded here instead of in the fixture.
- **The corpus baseline had slack.** It was 0.95 / 0.93 against a measured
  320/323 and 311/323, so up to a dozen regressions would have passed silently,
  which is not what §11 says. The first CI run printed exactly the mirror's
  numbers, so the baseline is now 0.99 / 0.96 — at 323 lines, one lost line on
  either side fails the build. Adding a row that does not pass means bumping the
  baseline on purpose in the same change, which is the point.
- **The model may overwrite a stated quantity or unit.** `ModelIngredientMapping`
  accepts any finite model quantity where the regex found one (2 → 3, "2–3" →
  2.5), any known unit spelling (cup → tbsp, which moves the line between sums),
  and replaces the note wholesale (dropping the range text). Tests pin all of it,
  so it is a decision, not an accident — but it sits uneasily next to "never
  invent a number".
- **Ranges are summed at their lower bound**: "2–3 cloves" + "2 cloves" shows 4.
  §8 permits it; §1 might not.
- **Embedding work on the main thread.** The matcher's `load()` runs in
  `AppModel.init`, and the first `makePipeline()` embeds every canonical name
  synchronously on the main actor; the same non-thread-safe matcher is then used
  off-main by the pipeline. Unverifiable without a device.
- **The model prompt may overflow its context** on recipes past roughly twenty
  lines (`004` lists it as open).
- **`setChecked` can store a check for an ingredient no selected recipe
  contributes** (only reachable through a stale list after a failed read), and
  `SQLiteDB.execute` bypasses the reads-only check that `prepare` enforces
  (latent: every `execute` write is inside `transaction` today).
- **Type roles the design system cannot meet as written**: buttons and the
  empty-state title render SF Rounded in the vendored components, while §4.2
  asks for Inter and Fraunces. `Theme.swift`'s own CTA style could switch; the
  package cannot be edited here.
- The inbox is not atomic across processes (the extension and the app are never
  active together on an iPhone-only app, so theoretical today); a checked heading
  in *Other* renders above unchecked text rows; `&Eacute;` decodes lowercase;
  number-word ranges ("two to three") are not parsed; the extension activates for
  any `public.text` but only handles plain text.
