#!/usr/bin/env python3
"""Python mirror of RecipeToGroceryList/Model/Normalize.swift (IngredientNormalizer).

Purpose:           Give build_seed.py the exact §7.1 normalization the app uses, so
                   the seed's alias-uniqueness and slug checks agree with the
                   runtime (`ingredient_aliases.alias` PRIMARY KEY, layer 0/1/1.5).
When to use:       Imported by scripts/build_seed.py. Run directly for the self-test.
Safe to run in prod?  Yes — pure functions, no I/O beyond the self-test's stdout.
Owner:             Luke F. Walton

This file is a STEP-FOR-STEP port, not a re-derivation: every function below sits
opposite a `static func` of the same name in Normalize.swift, in the same order,
with the same branches. If Normalize.swift changes, change this file in the same
PR. `SeedIngredientsTests` re-checks the seed invariants at runtime with the Swift
code, so any drift between the two shows up as a failing test rather than as a
silently dropped alias at seed time.

Where Python and Foundation are not literally the same API, the mapping is:

  Swift                                              Python
  ------------------------------------------------   -------------------------------------
  precomposedStringWithCompatibilityMapping          unicodedata.normalize("NFKC", s)
  folding(.diacriticInsensitive, .caseInsensitive)   NFD → drop Mn marks → NFC, then .lower()
  Character.isWhitespace (split)                     str.split() (Unicode whitespace)
  CharacterSet.punctuationCharacters / .symbols      unicodedata.category(ch)[0] in "PS"
  Character.isLetter                                 str.isalpha()
  Character.isNumber                                 str.isnumeric()
  CharacterSet.alphanumerics                         unicodedata.category(ch)[0] in "LMN"

The residual differences (Foundation's `isLetter` also accepts a few
Other_Alphabetic marks; Python's `isspace` accepts U+001C..U+001F) cannot arise
in the seed, which is ASCII plus a handful of Latin diacritics that step 2 strips.
"""

from __future__ import annotations

import unicodedata

# Normalize.swift — `articles`
ARTICLES: frozenset[str] = frozenset({"a", "an", "the"})

# Normalize.swift — `singularExceptions`. Mass nouns and proper names that end in
# "s" but are not plurals; kept verbatim so seed aliases read right.
SINGULAR_EXCEPTIONS: frozenset[str] = frozenset({
    "hummus", "couscous", "molasses", "asparagus", "swiss", "brussels",
    "grits", "oats", "greens", "chips", "flakes", "sprinkles",
})

# Normalize.swift — the `for suffix in [...]` list inside `singularize`, same order.
_DROP_TWO_SUFFIXES: tuple[str, ...] = ("oes", "ches", "shes", "sses", "xes", "zes")


def _fold(text: str) -> str:
    """Steps 1–2 of `normalize` and the head of `slugify`: NFKC, strip diacritics,
    lowercase.

    Swift: `raw.precomposedStringWithCompatibilityMapping.folding(options:
    [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()`.
    Foundation's diacritic-insensitive fold decomposes, drops the combining marks
    and recomposes; NFD → filter category Mn → NFC is the same operation spelled
    out. Every Latin accent (jalapeño, crème, fraîche, pimentón) is an Mn mark.
    """
    text = unicodedata.normalize("NFKC", text)
    decomposed = unicodedata.normalize("NFD", text)
    without_marks = "".join(ch for ch in decomposed if unicodedata.category(ch) != "Mn")
    return unicodedata.normalize("NFC", without_marks).lower()


def _is_punctuation(ch: str) -> bool:
    """Swift `isPunctuation(_:)`: CharacterSet.punctuationCharacters (Unicode
    general category P*) or CharacterSet.symbols (S*)."""
    return unicodedata.category(ch)[0] in ("P", "S")


def removing_parentheticals(text: str) -> str:
    """Swift `removingParentheticals`: drop every `( … )` group, nested ones
    included, and any unbalanced opener through to the end of the string."""
    result: list[str] = []
    depth = 0
    for character in text:
        if character == "(":
            depth += 1
        elif character == ")":
            if depth > 0:
                depth -= 1
        elif depth == 0:
            result.append(character)
    return "".join(result)


def trimming_punctuation(token: str) -> str:
    """Swift `trimmingPunctuation`: strip leading and trailing punctuation/symbol
    scalars from one token, keeping interior ones ("half-and-half" survives,
    "onion," and "*salt*" are cleaned). Operates on code points, as Swift does on
    unicode scalars."""
    start = 0
    end = len(token)
    while start < end and _is_punctuation(token[start]):
        start += 1
    while end > start and _is_punctuation(token[end - 1]):
        end -= 1
    return token[start:end]


def singularize(word: str) -> str:
    """Swift `singularize`: one trailing plural on words longer than 3 characters
    ("tomatoes → tomato, but hummus stays"). Branch order is the Swift order.

    Letters and hyphens qualify, so a hyphenated compound singularizes too
    ("chick-peas" → "chick-pea") and layer 1.5's key joins it with "chick peas"
    and "chickpeas". Anything else with a non-letter ("m&ms") is left alone."""
    # guard word.count > 3, word.allSatisfy({ $0.isLetter || $0 == "-" })
    # (After `_fold` no combining marks remain, so len() == Swift's Character count.)
    if len(word) <= 3 or not all(ch.isalpha() or ch == "-" for ch in word):
        return word
    if word in SINGULAR_EXCEPTIONS:
        return word
    if word.endswith("ies") and len(word) > 4:
        return word[:-3] + "y"                      # berries → berry
    for suffix in _DROP_TWO_SUFFIXES:
        if word.endswith(suffix):
            return word[:-2]                        # tomatoes → tomato, peaches → peach
    if word.endswith("us") or word.endswith("ss") or word.endswith("is"):
        return word                                 # hummus, molasses, … stay
    if word.endswith("s"):
        return word[:-1]                            # onions → onion
    return word


def normalize(raw: str) -> str:
    """Swift `normalize`: §7.1 in order — lowercase, NFKC, strip diacritics, drop
    parentheticals, collapse whitespace, trim, strip leading/trailing punctuation
    per token, remove a leading article, singularize the last word."""
    text = _fold(raw)
    text = removing_parentheticals(text)
    # `split(whereSeparator: { $0.isWhitespace })` omits empty subsequences, so a
    # run of whitespace collapses to one boundary — exactly str.split().
    tokens = text.split()
    tokens = [stripped for stripped in (trimming_punctuation(t) for t in tokens) if stripped]
    # A leading article only when something follows it ("a" alone stays "a").
    if len(tokens) > 1 and tokens[0] in ARTICLES:
        tokens.pop(0)
    if tokens:
        tokens[-1] = singularize(tokens[-1])
    return " ".join(tokens)


def loose_key(raw: str) -> str:
    """Swift `looseKey`: the normalized form with every non-alphanumeric removed
    (CharacterSet.alphanumerics = categories L*, M*, N*)."""
    return "".join(ch for ch in normalize(raw) if unicodedata.category(ch)[0] in ("L", "M", "N"))


def slugify(name: str) -> str:
    """Swift `slugify`: fold, drop ASCII apostrophes, then every run of
    non-(letter|number) becomes one underscore ("Crème Fraîche" → "creme_fraiche").
    Only U+0027 is removed — a curly ’ is punctuation and becomes a separator, as
    in Swift."""
    lowered = _fold(name).replace("'", "")
    parts: list[str] = []
    current: list[str] = []
    for ch in lowered:
        if ch.isalpha() or ch.isnumeric():
            current.append(ch)
        elif current:
            parts.append("".join(current))
            current = []
    if current:
        parts.append("".join(current))
    return "_".join(parts)


def _self_test() -> None:
    """The examples from Normalize.swift's doc comments plus the cases
    IngredientNormalizerTests pins, so this mirror fails loudly if it drifts."""
    cases = [
        # singularize — doc comments
        (singularize, "tomatoes", "tomato"),
        (singularize, "hummus", "hummus"),
        (singularize, "berries", "berry"),
        (singularize, "peaches", "peach"),
        (singularize, "onions", "onion"),
        (singularize, "molasses", "molasses"),
        (singularize, "radishes", "radish"),
        (singularize, "boxes", "box"),
        (singularize, "pies", "pie"),            # "ies" only when longer than 4
        (singularize, "peas", "pea"),
        (singularize, "gas", "gas"),             # not longer than 3
        (singularize, "oats", "oats"),           # exception
        (singularize, "asparagus", "asparagus"),
        (singularize, "bass", "bass"),
        (singularize, "chips", "chips"),
        # The exception set is case-sensitive; capitalised input keeps its s via -ss.
        (singularize, "Swiss", "Swiss"),
        # Hyphens qualify, so a compound singularizes and layer 1.5's key joins the
        # three spellings of chickpea; anything else with a non-letter is left alone.
        (singularize, "half-and-half", "half-and-half"),   # no trailing s to strip
        (singularize, "chick-peas", "chick-pea"),
        (singularize, "m&ms", "m&ms"),
        (singularize, "2%s", "2%s"),
        # normalize — doc comments and §7.1
        (normalize, "the Green Onions", "green onion"),
        (normalize, "jalapeño (fresh)", "jalapeno"),
        (normalize, "(fresh) Jalapeños", "jalapeno"),
        (normalize, "Crème Fraîche", "creme fraiche"),
        (normalize, "  Vegetable   Broth ", "vegetable broth"),
        (normalize, "  Kosher   Salt ", "kosher salt"),
        (normalize, "Bell\tPepper\n", "bell pepper"),
        (normalize, "onion,", "onion"),
        (normalize, "*salt*", "salt"),
        (normalize, "half-and-half", "half-and-half"),
        (normalize, "a", "a"),
        (normalize, "an egg", "egg"),
        (normalize, "a pinch", "pinch"),
        (normalize, "the onions,", "onion"),
        (normalize, "Brussels sprouts", "brussels sprout"),
        (normalize, "Chick peas", "chick pea"),
        (normalize, "Chick-Peas", "chick-pea"),
        (normalize, "salt & pepper", "salt pepper"),
        (normalize, "2% milk", "2 milk"),
        (normalize, "Tomatoes (diced (small))", "tomato"),
        (normalize, "bay leaves", "bay leave"),  # irregular plural is a legitimate alias
        (normalize, "confectioners' sugar", "confectioners sugar"),
        (normalize, "", ""),
        (normalize, "   ", ""),
        (normalize, "( )", ""),
        (normalize, "(only a note)", ""),
        (normalize, "...", ""),
        # looseKey
        (loose_key, "chick peas", "chickpea"),
        (loose_key, "Chickpea", "chickpea"),
        (loose_key, "chickpeas", "chickpea"),
        (loose_key, "chick-peas", "chickpea"),    # the three spellings meet here
        (loose_key, "Green-onion", "greenonion"),
        (loose_key, "green onion", "greenonion"),
        (loose_key, "half-and-half", "halfandhalf"),
        (loose_key, "(x)", ""),
        # slugify
        (slugify, "Crème Fraîche", "creme_fraiche"),
        (slugify, "Half-and-half", "half_and_half"),
        (slugify, "Ben's Beans", "bens_beans"),
        (slugify, "  Olive  Oil ", "olive_oil"),
        (slugify, "All-purpose flour", "all_purpose_flour"),
        (slugify, "Za'atar", "zaatar"),
        (slugify, "Jalapeño", "jalapeno"),
        (slugify, "Monterey Jack cheese", "monterey_jack_cheese"),
        (slugify, "2% milk", "2_milk"),
        (slugify, "", ""),
        (slugify, "***", ""),
        # pieces
        (removing_parentheticals, "a (b (c)) d", "a  d"),
        (removing_parentheticals, "a (b", "a "),
        (removing_parentheticals, "a) b", "a b"),
        (removing_parentheticals, "plain", "plain"),
        (trimming_punctuation, "onion,", "onion"),
        (trimming_punctuation, "*salt*", "salt"),
        (trimming_punctuation, "half-and-half", "half-and-half"),
        (trimming_punctuation, "...", ""),
        (trimming_punctuation, "\"quoted\"", "quoted"),
        (trimming_punctuation, "$5", "5"),        # symbols count as punctuation
    ]
    # NFKC: "½" folds to "1⁄2", so the two spellings meet (IngredientNormalizerTests).
    if normalize("½ cup") != normalize("1⁄2 cup"):
        failures_nfkc = [f"normalize('½ cup') = {normalize('½ cup')!r} != normalize('1⁄2 cup') = {normalize('1⁄2 cup')!r}"]
    else:
        failures_nfkc = []
    # Idempotence: normalizing a normalized string is a no-op.
    for raw in ["Tomatoes", "the Green Onions", "Crème fraîche (fresh)", "berries", "glasses", "peaches"]:
        once = normalize(raw)
        if normalize(once) != once:
            failures_nfkc.append(f"normalize is not idempotent on {raw!r}: {once!r} → {normalize(once)!r}")
    failures = list(failures_nfkc)
    for fn, given, expected in cases:
        got = fn(given)
        if got != expected:
            failures.append(f"{fn.__name__}({given!r}) = {got!r}, expected {expected!r}")
    if failures:
        raise SystemExit("FAILED — ingredient_normalize.py drifted from Normalize.swift:\n"
                         + "\n".join(failures))
    print(f"ingredient_normalize.py: {len(cases) + 7} cases OK")


if __name__ == "__main__":
    _self_test()
