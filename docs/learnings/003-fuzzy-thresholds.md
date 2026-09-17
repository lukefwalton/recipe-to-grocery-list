# 003 — Calibrating fuzzy resolution on food (gate 3)

SPEC §13 left the fuzzy and embedding thresholds open with one instruction:
"start at workout values (0.78 / 0.85), recalibrate on the corpus, **expect
tighter**." This is what the corpus said, and the two changes it forced.

## The metric needed two food-specific guards, not just a number

`workout-logger`'s `FuzzyMatch` (at `5bffddfb80fc`) averages Jaro–Winkler over the
*query's* tokens and takes the best of that and the whole-string score. For lifts
that is fine. For food it resolves the exact traps SPEC §7.4 names, in two
different directions:

**1. A short query inside a longer name.** The directed token average gives
`cream` a perfect 1.0 against "sour cream", because every query token is present.
Fix: make the token metric **symmetric** — the minimum of both directions — so the
candidate's extra words cost something too. `cream` / "Sour cream" is 0.5.

**2. A short query that is a *prefix*.** The whole-string Jaro–Winkler matches all
of `chicken` inside "chicken broth" and then collects the four-character prefix
bonus: 0.91. Fix: consult the whole-string score **only when both sides have the
same number of words**. Different word counts are decided by the symmetric token
metric alone.

Both were in place before the corpus ran. The corpus then found a third.

**3. A shared modifier.** `grated gruyère` scored 0.87 against the alias *grated
nutmeg*, and `shredded carot` 0.92 against *shredded cheddar* — carried entirely
by the first word, with the head noun ignored. In a food name the identity is the
last word: "grated X" is X. Fix: **a pair is at most as similar as its head
nouns.** The traps fall to 0.54 and 0.50; real matches are untouched because their
heads agree (`veggie broth` / "Vegetable broth" heads match exactly,
`bell peper` / "Bell pepper" = 0.96). Measured over all 320 corpus lines: four
wrong matches removed, **nothing else moved**.

The cap also closed one nobody had noticed: **baking soda vs baking powder** scored
0.90 and would have resolved. Two different leaveners. It is now 0.61.

## The threshold: 0.78 → 0.86

With the metric fixed, the threshold was swept over the corpus. The column that
matters is *wrong matches*, because the two failure modes are not symmetric — a
wrong match is a wrong ingredient the user may well accept in Confirm, while a
miss lands in *New* and costs one deliberate tap (§7.5):

| threshold | correct | wrong match | missed real |
|---|---|---|---|
| 0.78 | 94.7% | 7 | 10 |
| 0.82 | 95.0% | 4 | 12 |
| 0.84 | 95.9% | 1 | 12 |
| **0.86** | **96.3%** | **0** | **12** |
| 0.87 | 94.7% | 0 | 17 |
| 0.90 | 93.4% | 0 | 21 |

0.86 is where wrong matches reach zero, and it is also the peak of raw accuracy;
past it only misses accumulate. The seven casualties at 0.78 were all exotic
ingredients absent from the seed being pulled onto a near neighbour — saffron →
Salmon, ong choy → Bok choy, calamansi juice → Lemon juice, ube jam → Jam. Exactly
the "never guess" failure the doctrine forbids.

## A structural consequence: the escalation bar had to move too

Layer 3 is consulted only "when fuzzy is below its escalation bar", and its results
are *additive, never displacing* (§7.4). With the fuzzy threshold at 0.86 and the
bar still at 0.85, **every** fuzzy hit would clear the bar and that additive path
would be unreachable dead code — the semantic layer could only ever run when fuzzy
found nothing at all.

The spec's original pair kept the bar 0.07 above the threshold (0.78 / 0.85), so
the gap moves with it: the bar is now **0.93**. A marginal fuzzy hit (0.86…0.93,
`sour creme` → Sour cream at 0.907) can still gather semantic alternatives for the
picker; a confident one skips the embedding entirely. `IngredientResolverTests`
pins the invariant that the bar sits above the threshold, so this can't silently
regress.

## How this was measured without a Swift toolchain

`scripts/reference_parser.py` is a line-for-line port of the splitter, the metric
and resolution layers 0–2. It runs the corpus (`--selftest` re-checks 354 designed
cases and 17 pinned similarity values against the Swift's documented behaviour), so
a drift between the two shows up as a failure rather than a mystery. Every number
in `FuzzyMatchTests` was produced by that port before being asserted.

Final corpus standing: **splitter 98.75%**, **resolution 96.25%**, baselines
recorded at 0.95 / 0.93. The twelve remaining resolution misses are honest grammar
limits, not wrong answers — OCR damage the splitter can't repair ("O.5 cup water",
"l tbsp olive oil"), a leading prep word ("shredded carot" — only *trailing* prep
words move to the note), and constructions the grammar doesn't parse ("1 x 400g
tin", "Juice and zest of 1 lime", "2 cups plus 2 tablespoons"). Each lands in
*New*: visible, one tap, never wrong.

## What is still open

The thresholds are calibrated against a corpus this repo authored. Real pages will
be rougher. The numbers are instance properties on `IngredientResolver`, the
corpus baseline is a fixture, and the pass rate prints on every CI run — so the
next calibration is an edit and a re-run, not a rewrite.
