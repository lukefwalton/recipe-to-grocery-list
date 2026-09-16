# 004 — Foundation Models: one request per recipe, per-row fallback (gate 4)

The workout app's adapter (`Parsing/FoundationWorkoutParser.swift`,
`Parsing/ModelDraftMapping.swift`, `Parsing/WorkoutParserOrchestrator.swift` at
`workout-logger@5bffddfb80fc`, written up in its `docs/learnings/013`) is the
template: total module isolation, an FM-free mapping layer that carries the
defensive logic and is unit-tested, a factory that wires the model only when the
SDK, the OS and the runtime availability all agree, and a `macos-26` CI job that
proves the gated branch compiles. SPEC §3 names the two deliberate departures;
this entry records how they were built.

## Per-row results, not all-or-nothing

`ModelDraftMapping.result` declines a whole workout entry if any set is
unreadable. A recipe has 5–30 lines and one weird one ("a splash of something")
must not cost the other fourteen, so `ModelIngredientMapping.merge(regex:model:)`
works line by line:

- The regex splitter (§7.2) always runs first; the model only **refines** its
  output. Rows are matched to input lines by exact `rawLine` (trimmed, case-
  sensitive — "unchanged" means unchanged). A model row for a line that does not
  exist is ignored; an input line the model skipped keeps its regex result with
  confidence `high`. The model can never add or remove a line.
- A model `quantity` is accepted only where the regex found one and the value is
  finite and ≥ 0 — the model may correct a number, never invent one. A unit is
  accepted only if `UnitTable.key(forSpelling:)` recognises it. Names and notes are
  taken when non-empty, otherwise the regex value stands.
- An unknown `confidence` string maps to `low`, never up.
- The whole response is `nil` (declined) only when the model errors or the
  response is unparseable; then every line uses regex + layers 0–3 and the UI
  says "Parsed without on-device AI."

`canonicalGuess` never resolves a row. `IngredientResolver.resolveRow` runs
layers 0–3 on the row's *name*; only when nothing hits does it run layers 0–1.5
on the guess, and a hit there becomes a **suggestion** ("Looks like X", `via:
.llm`) that needs a Use tap. The model proposes; the user confirms; the store
writes the alias inside `save`.

## No clarification loop

`ParseOutcome` here is `draft | declined`. The Confirm screen is the clarification
step: low-confidence and unresolved rows are surfaced there, with Create / Same
as… / Keep as text, instead of asking the model a follow-up question per line.
`FoundationRecipeParser.refine` is therefore one `LanguageModelSession` and one
`respond(to:generating:)` per recipe, with the known canonical names in the
*instructions* and the user's lines in the *prompt* (the documented pattern, and
what keeps a pasted line from rewriting the rules).

## Suggested rows block Save

SPEC §7.5 says Save is disabled while a row is in the *New* state. A *Suggested*
row has no ingredient either; accepting it silently at Save would let the model
write an alias with no tap, which §7.5 forbids. So `DraftRow.blocksSave` is true
for `.new` **and** `.suggested`; both need a decision.

## What is verified, and where

`ModelIngredientMappingTests` (32 cases) and `RecipePipelineTests` (22) run with
a scripted `FakeRefiner` and no FoundationModels import: skipped lines, invented
lines, invented quantities, junk confidence, unit spellings, the guess-becomes-
suggestion path, and the warning copy. The gated file is correct-by-inspection —
its symbols (`SystemLanguageModel.default.availability`,
`LanguageModelSession(instructions:)`, `respond(to:generating:)`,
`Response.content`, `@Generable`/`@Guide`) follow the workout adapter and must be
checked against the installed SDK in Xcode; the `foundation-models-guard` job is
what compiles it. One device-side question is open: the instructions embed the
full canonical list (~350 names), which together with a long recipe could
approach the on-device context window; an overflow throws, is caught, and
degrades to the regex path, so the failure is graceful — whether to cap the list
is a gate-9 call.
