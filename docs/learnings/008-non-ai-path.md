# 008 — The device without Apple Intelligence (gate 9)

"Usable without AI" is a principle in §1 and a first-class gate in §12, not a
fallback bolted on at the end. This records what that actually means in the code,
what the corpus says it costs, and the one part that is still owed a device.

## The whole app runs with `refiner == nil`

`RecipePipeline` holds the on-device model as a plain `RecipeRefining?`.
`RecipeParserFactory.makeRefiner()` returns nil unless three things agree: the SDK
is present at compile time (`#if canImport(FoundationModels)`), the OS is new
enough (`#available(iOS 26.0, *)`), and the model reports itself available at
runtime. Otherwise every stage still runs:

- §7.1 normalization — deterministic, always
- §7.2 the regex splitter — deterministic, always
- §7.4 layers 0–1.5 (exact, alias, loose key) — deterministic, always
- §7.4 layer 2 (fuzzy) — deterministic, always
- §7.4 layer 3 (embeddings) — opportunistic, and *separately* gated on
  `NaturalLanguage` plus asset availability, so it is often absent too
- §7.5 Confirm — unchanged

Only layer 4 disappears. The consequence is exactly what the spec predicts: more
rows land in *New* and need a tap. Nothing is wrong, nothing is missing, and
nothing silently degrades — the copy says so in the user's words
(`RecipeParserFactory.unavailableCopy`: "On-device AI isn't available on this
device; a few more rows may need a tap."), shown on the Add screen and again on
Confirm.

There is a second, distinct case: the model *is* available but declines or errors.
Then every line keeps its regex result and Confirm shows "Parsed without on-device
AI." Two different sentences because they are two different situations.

## What it costs, measured

The golden corpus (§11) scores the deterministic path end to end, layers 0–2 only,
with `NoopEmbedding` — i.e. precisely a device with no Apple Intelligence and no
embedding assets:

| | rate |
|---|---|
| splitter (quantity, unit, name, note all correct) | **98.75%** |
| resolution (right canonical, or correctly nothing) | **96.25%** |

That is the floor, not the ceiling: the model can only improve on it, and the
per-row mapping (`004`) means it can never make a line worse than its regex
reading. A device with Apple Intelligence gets tidier names and a `canonicalGuess`
that turns some *New* rows into one-tap *Suggested* rows. A device without it gets
a working app.

`GoldenCorpusTests` prints both rates on every CI run and fails below the recorded
baselines, so this number can't quietly rot.

## CI proves both branches compile

A green build on a toolchain without the SDK proves only the fallback — the FM
branch would have silently vanished. So `ios-tests.yml` runs two jobs on different
runners: the unit suite on `macos-14`, and `foundation-models-guard` on `macos-26`,
which first type-checks a probe file that `#error`s unless `FoundationModels` is
importable, then builds with the branch genuinely compiled in. Inherited from
`workout-logger` (`013-foundation-models.md`), and the reason it exists there
applies here unchanged.

## What is still owed (the gate is not closed)

Everything above is structural and measured. What remains is a human on a device:

- [ ] A clean install on an iPhone **without** Apple Intelligence: onboard, paste a
      recipe, confirm, save, select it, shop the list.
- [ ] The same on a device **with** it, to see the same recipe parse both ways and
      confirm the copy is right in each case.
- [ ] Confirm the `unavailableCopy` sentence actually appears (and the
      "Parsed without on-device AI" one, by turning Apple Intelligence off
      mid-session).
- [ ] Record the corpus pass rate observed on device against the CI number.

Until those are ticked, gate 9 is open. This file is where the result goes.
