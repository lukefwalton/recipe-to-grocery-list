#!/usr/bin/env python3
"""Python mirror of the deterministic parse pipeline, used to score the golden corpus.

Purpose:           Reproduce Parsing/{LineCleaner,QuantityParser,IngredientLineSplitter,
                   IngredientIndex,IngredientResolver}.swift and Model/{Units,FuzzyMatch}.swift
                   exactly, so RecipeToGroceryListTests/Fixtures/ingredient_lines.json can be
                   authored, scored and calibrated where there is no Swift toolchain
                   (docs/learnings/001-scaffold-and-inheritance.md).
When to use:       Dev only. `--selftest` before touching the corpus (it fails loudly when the
                   Swift grammar and this mirror drift); then pass the fixture to print the two
                   pass rates and every mismatch. Never shipped, never imported by the app.
Safe to run in prod?  Not applicable — it is not part of the app or of CI. Pure and read-only:
                   it reads the fixture and the bundled seed and writes nothing.
Owner:             Luke F. Walton

This is a STEP-FOR-STEP port, like scripts/ingredient_normalize.py: every function sits
opposite a `static func` of the same name in the Swift, in the same order, with the same
branches and the same magic numbers. §7.1 normalization is *not* re-derived here — it is
imported from ingredient_normalize.py, so the seed build, this scorer and the app can only
ever agree. `--selftest` asserts the designed cases the Swift authors pinned in
IngredientLineSplitterTests / QuantityParserTests / UnitTableTests / LineCleanerTests and the
exact similarity values asserted in FuzzyMatchTests, so a change on either side is loud.

Scoring (the same comparison GoldenCorpusTests.swift makes, so the rates agree):

  splitter    quantity within 1e-6 (null == null) AND unit_key equal AND name equal after
              whitespace collapse + casefold AND note equal the same way (null == null)
  resolution  the seed slug of the layer-0…2 hit for the *parsed* name equals the expected
              slug (null == null) — layer 3 is off, as it is on every non-embedding device

Usage:
    python3 scripts/reference_parser.py --selftest
    python3 scripts/reference_parser.py RecipeToGroceryListTests/Fixtures/ingredient_lines.json
    python3 scripts/reference_parser.py --explain "2 cups vegetable broth"
"""

from __future__ import annotations

import argparse
import json
import sys
import unicodedata
from pathlib import Path

# Import the §7.1 normalizer mirror from this directory regardless of the cwd, exactly as
# build_seed.py does, and with the same no-bytecode rule so scripts/__pycache__/ never
# appears in the repo.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from ingredient_normalize import loose_key, normalize  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SEED = REPO_ROOT / "RecipeToGroceryList" / "Resources" / "seed_ingredients.json"
DEFAULT_FIXTURE = REPO_ROOT / "RecipeToGroceryListTests" / "Fixtures" / "ingredient_lines.json"


# ---------------------------------------------------------------------------
# Model/Units.swift — UnitTable
# ---------------------------------------------------------------------------

# UnitTable.all, copied row for row: (key, spellings, caseSensitiveSpellings).
UNITS: tuple[tuple[str, tuple[str, ...], tuple[str, ...]], ...] = (
    ("tsp", ("tsp", "tsps", "teaspoon", "teaspoons"), ("t",)),
    ("tbsp", ("tbsp", "tbsps", "tablespoon", "tablespoons", "tbs", "tbl"), ("T",)),
    ("cup", ("cup", "cups", "c"), ()),
    ("floz", ("fl oz", "fl. oz", "fl.oz", "floz", "fluid ounce", "fluid ounces"), ()),
    ("oz", ("oz", "ounce", "ounces"), ()),
    ("lb", ("lb", "lbs", "pound", "pounds"), ()),
    ("g", ("g", "gram", "grams"), ()),
    ("kg", ("kg", "kilogram", "kilograms"), ()),
    ("ml", ("ml", "milliliter", "milliliters", "millilitre", "millilitres"), ()),
    ("l", ("l", "liter", "liters", "litre", "litres"), ()),
    ("quart", ("quart", "quarts", "qt", "qts"), ()),
    ("pint", ("pint", "pints", "pt", "pts"), ()),
    ("gallon", ("gallon", "gallons", "gal"), ()),
    ("clove", ("clove", "cloves"), ()),
    ("can", ("can", "cans", "tin", "tins"), ()),
    ("jar", ("jar", "jars"), ()),
    ("bottle", ("bottle", "bottles"), ()),
    ("bag", ("bag", "bags"), ()),
    ("box", ("box", "boxes"), ()),
    ("bunch", ("bunch", "bunches"), ()),
    ("pinch", ("pinch", "pinches"), ()),
    ("dash", ("dash", "dashes"), ()),
    ("handful", ("handful", "handfuls"), ()),
    ("piece", ("piece", "pieces", "whole"), ()),
    ("slice", ("slice", "slices"), ()),
    ("stick", ("stick", "sticks"), ()),
    ("stalk", ("stalk", "stalks", "rib", "ribs"), ()),
    ("head", ("head", "heads"), ()),
    ("sprig", ("sprig", "sprigs"), ()),
    ("package", ("package", "packages", "pkg", "pkgs", "packet", "packets"), ()),
)

UNIT_KEYS: tuple[str, ...] = tuple(key for key, _, _ in UNITS)
# UnitTable.byLowercasedSpelling / byCaseSensitiveSpelling.
_BY_LOWERCASED_SPELLING: dict[str, str] = {s.lower(): k for k, ss, _ in UNITS for s in ss}
_BY_CASE_SENSITIVE_SPELLING: dict[str, str] = {s: k for k, _, cs in UNITS for s in cs}
# UnitTable.spellingsLongestFirst: `Array(Set(...)).sorted { count desc, then a < b }`.
_SPELLINGS_LONGEST_FIRST: tuple[str, ...] = tuple(
    sorted({s for _, ss, cs in UNITS for s in ss + cs}, key=lambda s: (-len(s), s))
)


def is_known_key(key: str) -> bool:
    """Swift `UnitTable.isKnownKey`."""
    return key in UNIT_KEYS


def key_for_spelling(spelling: str) -> str | None:
    """Swift `UnitTable.key(forSpelling:)`: trim spaces, tolerate trailing periods, then
    the case-sensitive table (`T`/`t`) before the case-insensitive one."""
    text = spelling.strip(" \t")
    while text.endswith("."):
        text = text[:-1]
    if not text:
        return None
    if text in _BY_CASE_SENSITIVE_SPELLING:
        return _BY_CASE_SENSITIVE_SPELLING[text]
    return _BY_LOWERCASED_SPELLING.get(text.lower())


def is_spelling(spelling: str) -> bool:
    """Swift `UnitTable.isSpelling`."""
    return key_for_spelling(spelling) is not None


def longest_unit_match(text: str) -> tuple[str, str] | None:
    """Swift `UnitTable.longestMatch(atStartOf:)`: longest accepted spelling at the start of
    `text` (after leading *spaces* only), requiring end-of-text, whitespace, `.`, `,` or `)`
    after it. Returns (key, matchedText) so `unit_text` can keep the author's spelling.
    `T`/`t` compare case-sensitively; every other spelling ignores case."""
    trimmed = text.lstrip(" ")
    if not trimmed:
        return None
    for spelling in _SPELLINGS_LONGEST_FIRST:
        if len(trimmed) < len(spelling):
            continue
        head = trimmed[: len(spelling)]
        if spelling in _BY_CASE_SENSITIVE_SPELLING and len(spelling) == 1:
            matches = head == spelling
        else:
            matches = head.lower() == spelling.lower()
        if not matches:
            continue
        rest = trimmed[len(spelling):]
        if rest and not (rest[0].isspace() or rest[0] in ".,)"):
            continue
        key = key_for_spelling(head)
        if key is None:
            continue
        return key, head
    return None


# ---------------------------------------------------------------------------
# Parsing/LineCleaner.swift
# ---------------------------------------------------------------------------

# LineCleaner.bulletGlyphs.
BULLET_GLYPHS: frozenset[str] = frozenset("-–—*•·▢☐✓✔>◦▪■□○●")


def _dropping_numbering(text: str) -> str | None:
    """Swift `LineCleaner.droppingNumbering`: the text after one numbering token, or None
    when the line is not numbered. Accepts "12." (period then whitespace or end), "12)",
    "(12)" and one circled digit U+2460…U+2473."""
    if not text:
        return None
    first = text[0]
    if 0x2460 <= ord(first) <= 0x2473:
        return text[1:]
    rest = text
    parenthesized = False
    if rest.startswith("("):
        parenthesized = True
        rest = rest[1:]
    digits = 0
    while digits < len(rest) and rest[digits].isascii() and rest[digits].isdigit():
        digits += 1
    if digits == 0 or digits > 3:
        return None
    rest = rest[digits:]
    if parenthesized:
        if not rest.startswith(")"):
            return None
        return rest[1:]
    if not rest:
        return None
    delimiter = rest[0]
    if delimiter == ")":
        return rest[1:]
    if delimiter == ".":
        after_period = rest[1:]
        if after_period and not after_period[0].isspace():
            return None                     # "1.5 cups" is a decimal, not numbering
        return after_period
    return None


def strip_bullet(line: str) -> str:
    """Swift `LineCleaner.stripBullet`: trim, then remove leading bullets and list
    numbering. Three passes cover "- 1. flour" style double decoration."""
    text = line.strip()
    for _ in range(3):
        while text and text[0] in BULLET_GLYPHS:
            text = text[1:].lstrip()
        after_numbering = _dropping_numbering(text)
        if after_numbering is None:
            break
        text = after_numbering.lstrip()
    return text


def is_section_header(line: str) -> bool:
    """Swift `LineCleaner.isSectionHeader`: ends with ":" and holds no digit anywhere
    (Unicode fractions count as digits, hence `isnumeric`, Swift's `isNumber`)."""
    trimmed = line.strip()
    if not trimmed.endswith(":"):
        return False
    return not any(ch.isnumeric() for ch in trimmed)


def clean_lines(lines: list[str]) -> list[tuple[str, bool]]:
    """Swift `LineCleaner.cleanLines`: (text, isSectionHeader) per surviving line. The only
    lines dropped are empty ones (§1 "nothing silently dropped")."""
    out: list[tuple[str, bool]] = []
    for line in lines:
        stripped = strip_bullet(line)
        if not stripped:
            continue
        out.append((stripped, is_section_header(stripped)))
    return out


# ---------------------------------------------------------------------------
# Parsing/QuantityParser.swift
# ---------------------------------------------------------------------------

# QuantityParser.numberWords — "one"…"twelve", deliberately no "half"/"dozen".
NUMBER_WORDS: dict[str, float] = {
    "one": 1.0, "two": 2.0, "three": 3.0, "four": 4.0, "five": 5.0, "six": 6.0,
    "seven": 7.0, "eight": 8.0, "nine": 9.0, "ten": 10.0, "eleven": 11.0, "twelve": 12.0,
}

# QuantityParser.vulgarFractions.
VULGAR_FRACTIONS: dict[str, float] = {
    "½": 1 / 2, "⅓": 1 / 3, "⅔": 2 / 3, "¼": 1 / 4, "¾": 3 / 4,
    "⅛": 1 / 8, "⅜": 3 / 8, "⅝": 5 / 8, "⅞": 7 / 8,
    "⅕": 1 / 5, "⅖": 2 / 5, "⅗": 3 / 5, "⅘": 4 / 5, "⅙": 1 / 6, "⅚": 5 / 6,
}

# QuantityParser.rangeDashes — hyphen, en dash, em dash, figure dash, minus sign.
RANGE_DASHES: frozenset[str] = frozenset("-–—‒−")
# QuantityParser.rangeWords.
RANGE_WORDS: tuple[str, ...] = ("to", "or")


def value_of_vulgar_fraction(ch: str) -> float | None:
    """Swift `QuantityParser.value(ofVulgarFraction:)`."""
    return VULGAR_FRACTIONS.get(ch)


def _is_ascii_digit(ch: str) -> bool:
    return ch.isascii() and ch.isdigit()


def _scan_digits(chars: list[str], i: int) -> int:
    """Swift `scanDigits`: index just past the run of ASCII digits starting at `i`."""
    j = i
    while j < len(chars) and _is_ascii_digit(chars[j]):
        j += 1
    return j


def _scan_number(chars: list[str], i: int) -> tuple[float, int] | None:
    """Swift `scanNumber`: one simple or mixed number starting exactly at `i` (no leading
    whitespace), as (value, end). Branch order is the Swift order."""
    n = len(chars)
    if i >= n:
        return None
    if chars[i] in VULGAR_FRACTIONS:
        return VULGAR_FRACTIONS[chars[i]], i + 1
    if chars[i] == "." and i + 1 < n and _is_ascii_digit(chars[i + 1]):
        j = _scan_digits(chars, i + 1)
        return float("0" + "".join(chars[i:j])), j
    if not _is_ascii_digit(chars[i]):
        return None
    j = _scan_digits(chars, i)
    whole = float("".join(chars[i:j]))

    # Decimal "1.5"
    if j + 1 < n and chars[j] == "." and _is_ascii_digit(chars[j + 1]):
        k = _scan_digits(chars, j + 1)
        return float("".join(chars[i:k])), k
    # ASCII fraction "1/2" (also U+2044)
    if j + 1 < n and chars[j] in "/⁄" and _is_ascii_digit(chars[j + 1]):
        k = _scan_digits(chars, j + 1)
        denominator = float("".join(chars[j + 1:k]))
        if denominator <= 0:
            return None
        return whole / denominator, k
    # Glued vulgar fraction "1½"
    if j < n and chars[j] in VULGAR_FRACTIONS:
        return whole + VULGAR_FRACTIONS[chars[j]], j + 1
    # Spaced vulgar fraction "1 ½"
    k = j
    while k < n and chars[k].isspace():
        k += 1
    if k > j and k < n and chars[k] in VULGAR_FRACTIONS:
        return whole + VULGAR_FRACTIONS[chars[k]], k + 1
    # Mixed ASCII fraction "1 1/2" or "1-1/2". A hyphen then digits with no slash ("2-3")
    # is left for the range scan.
    fraction_start: int | None = None
    if k > j and k < n and _is_ascii_digit(chars[k]):
        fraction_start = k
    elif j + 1 < n and chars[j] == "-" and _is_ascii_digit(chars[j + 1]):
        fraction_start = j + 1
    if fraction_start is not None:
        m = _scan_digits(chars, fraction_start)
        if m + 1 < n and chars[m] in "/⁄" and _is_ascii_digit(chars[m + 1]):
            p = _scan_digits(chars, m + 1)
            numerator = float("".join(chars[fraction_start:m]))
            denominator = float("".join(chars[m + 1:p]))
            if denominator > 0:
                return whole + numerator / denominator, p
    return whole, j


def _scan_range_tail(chars: list[str], i: int) -> int | None:
    """Swift `scanRangeTail`: index just past a second number introduced by a range
    separator after the number ending at `i`, else None."""
    n = len(chars)
    j = i
    while j < n and chars[j].isspace():
        j += 1
    if j >= n:
        return None
    if chars[j] in RANGE_DASHES:
        k = j + 1
        while k < n and chars[k].isspace():
            k += 1
        scanned = _scan_number(chars, k)
        return scanned[1] if scanned else None
    if j <= i:
        return None                          # "to" / "or" need whitespace before them
    for word in RANGE_WORDS:
        end = j + len(word)
        if not (end < n and chars[end].isspace()):
            continue
        if "".join(chars[j:end]).lower() != word:
            continue
        k = end
        while k < n and chars[k].isspace():
            k += 1
        scanned = _scan_number(chars, k)
        return scanned[1] if scanned else None
    return None


def _is_boundary(chars: list[str], i: int) -> bool:
    """Swift `isBoundary`: end of text, whitespace, a letter (a glued unit like "500ml"),
    "(" or "," — but not the thousands comma of "1,000", and not whitespace that only
    separates the number from a fraction slash ("1 /2"). Everything else ("10-inch",
    "2%", "1/2-inch") means no quantity."""
    if i >= len(chars):
        return True
    ch = chars[i]
    if ch == ",":
        return not (i + 1 < len(chars) and _is_ascii_digit(chars[i + 1]))
    if ch.isspace():
        j = i
        while j < len(chars) and chars[j].isspace():
            j += 1
        return not (j < len(chars) and chars[j] in "/⁄")
    return ch.isalpha() or ch == "("


def _remainder(chars: list[str], i: int) -> str:
    """Swift `remainder`: the text from `i`, leading whitespace removed."""
    j = i
    while j < len(chars) and chars[j].isspace():
        j += 1
    return "".join(chars[j:])


def _scan_word(chars: list[str], i: int) -> tuple[str, int]:
    """Swift `scanWord`: the run of non-whitespace, non-comma characters at `i`."""
    j = i
    while j < len(chars) and not chars[j].isspace() and chars[j] != ",":
        j += 1
    return "".join(chars[i:j]), j


def _next_token_is_unit(chars: list[str], i: int) -> bool:
    """Swift `nextTokenIsUnit`: whether the next word (or two, for "fl oz") is a unit
    spelling — the only case in which "a"/"an" means 1."""
    k = i
    while k < len(chars) and chars[k].isspace():
        k += 1
    first_text, first_end = _scan_word(chars, k)
    if not first_text:
        return False
    if is_spelling(first_text):
        return True
    m = first_end
    while m < len(chars) and chars[m].isspace():
        m += 1
    second_text, _ = _scan_word(chars, m)
    if not second_text:
        return False
    return is_spelling(first_text + " " + second_text)


def parse_leading_quantity(text: str) -> tuple[dict, str] | None:
    """Swift `QuantityParser.parse(leading:)`: ({value, text, rangeText}, remainder) or None.
    `value` is a range's lower bound; `rangeText` is set only for a range."""
    chars = list(text)
    start = 0
    while start < len(chars) and chars[start].isspace():
        start += 1
    if start >= len(chars):
        return None

    scanned = _scan_number(chars, start)
    if scanned is not None:
        value, end = scanned
        range_text: str | None = None
        range_end = _scan_range_tail(chars, end)
        if range_end is not None:
            end = range_end
            range_text = "".join(chars[start:end])
        if not _is_boundary(chars, end):
            return None
        quantity = {"value": value, "text": "".join(chars[start:end]), "rangeText": range_text}
        return quantity, _remainder(chars, end)

    # Number words and articles are whole words followed by whitespace, so "One-pot" and
    # "Onion" never read as "one".
    word_text, word_end = _scan_word(chars, start)
    if not (word_end < len(chars) and chars[word_end].isspace()):
        return None
    lowered = word_text.lower()
    if lowered in NUMBER_WORDS:
        quantity = {"value": NUMBER_WORDS[lowered], "text": word_text, "rangeText": None}
        return quantity, _remainder(chars, word_end)
    if lowered in ("a", "an") and _next_token_is_unit(chars, word_end):
        return {"value": 1.0, "text": word_text, "rangeText": None}, _remainder(chars, word_end)
    return None


# ---------------------------------------------------------------------------
# Parsing/IngredientLineSplitter.swift
# ---------------------------------------------------------------------------

# IngredientLineSplitter.prepWords, in the Swift's declaration order.
PREP_WORDS: tuple[str, ...] = (
    "diced", "minced", "chopped", "sliced", "divided", "to taste", "optional",
    "for serving", "for garnish", "peeled", "crushed", "grated", "shredded", "melted",
    "softened", "beaten", "cubed", "halved", "quartered", "thinly sliced",
    "finely chopped", "roughly chopped", "at room temperature",
)

# IngredientLineSplitter.sizeWords — multi-word spellings first.
SIZE_WORDS: tuple[str, ...] = ("extra-large", "extra large", "large", "medium", "small", "big")

# IngredientLineSplitter.openEndedNoteMarker.
OPEN_ENDED_NOTE_MARKER = "plus more"

_PREP_WORDS_LONGEST_FIRST: tuple[str, ...] = tuple(sorted(PREP_WORDS, key=lambda p: (-len(p), p)))


def collapse_whitespace(text: str) -> str:
    """Swift `collapseWhitespace`: `split(whereSeparator: isWhitespace).joined(separator: " ")`."""
    return " ".join(text.split())


def extract_parentheticals(text: str) -> tuple[str, list[str]]:
    """Swift `extractParentheticals`: removes every outermost `( … )` group (nested parens
    stay inside the note text) and returns their trimmed contents in order. An unbalanced
    "(" runs to the end of the line, like `IngredientNormalizer.removingParentheticals`."""
    out: list[str] = []
    notes: list[str] = []
    current: list[str] = []
    depth = 0
    for character in text:
        if character == "(":
            if depth == 0:
                out.append(" ")
            else:
                current.append(character)
            depth += 1
        elif character == ")" and depth > 0:
            depth -= 1
            if depth == 0:
                piece = collapse_whitespace("".join(current))
                if piece:
                    notes.append(piece)
                current = []
            else:
                current.append(character)
        elif depth > 0:
            current.append(character)
        else:
            out.append(character)
    if depth > 0:
        piece = collapse_whitespace("".join(current))
        if piece:
            notes.append(piece)
    return "".join(out), notes


def _dropping_leading_word(word: str, text: str) -> str | None:
    """Swift `dropping(leadingWord:from:)`: `text` without a leading whole `word`
    (case-insensitive) and the whitespace after it, or None."""
    if len(text) < len(word):
        return None
    if text[: len(word)].lower() != word:
        return None
    after = text[len(word):]
    if after and not after[0].isspace():
        return None
    return after.lstrip()


def _dropping_unit(matched_text: str, text: str) -> str:
    """Swift `droppingUnit`: drop the matched spelling (after the leading spaces
    `longestMatch` skipped), then one trailing "." and an "of"."""
    rest = text.lstrip(" ")[len(matched_text):]
    if rest.startswith("."):
        rest = rest[1:]
    rest = rest.lstrip()
    return _dropping_leading_word("of", rest) or rest


def _leading_size_word(name: str) -> str | None:
    """Swift `leadingSizeWord`: the size word at the start of a collapsed name, as written."""
    lowered = name.lower()
    for size in SIZE_WORDS:
        if lowered == size or lowered.startswith(size + " "):
            return name[: len(size)]
    return None


def _trailing_prep_phrase(name: str) -> str | None:
    """Swift `trailingPrepPhrase`: everything from the first " plus more" onward, else the
    longest prep phrase at the end of the collapsed name, as written."""
    lowered = name.lower()
    marker = lowered.find(" " + OPEN_ENDED_NOTE_MARKER)
    if marker >= 0:
        return name[marker + 1:]
    for phrase in _PREP_WORDS_LONGEST_FIRST:
        if lowered == phrase:
            return name
        if lowered.endswith(" " + phrase):
            return name[len(name) - len(phrase):]
    return None


def split(raw_line: str) -> dict:
    """Swift `IngredientLineSplitter.split`: one raw line → StructuredLine, in the
    documented order (bullets → parentheticals → quantity → unit → comma → size → prep →
    leading "of"). Note pieces join with ", " as parenthetical(s), range, size, prep, comma."""
    stripped = strip_bullet(raw_line)
    text, note_parts = extract_parentheticals(stripped)
    note_parts = list(note_parts)

    remainder = text.strip()
    quantity: float | None = None
    quantity_text: str | None = None
    range_note: str | None = None
    unit_key: str | None = None
    unit_text: str | None = None

    parsed = parse_leading_quantity(remainder)
    if parsed is not None:
        info, remainder = parsed
        quantity = info["value"]
        quantity_text = info["text"]
        range_note = info["rangeText"]
        unit = longest_unit_match(remainder)
        if unit is not None:
            unit_key, unit_text = unit
            remainder = _dropping_unit(unit_text, remainder)

    comma_note: str | None = None
    # Swift: the first comma not glued to a digit ("1,000 g" / "1,5 kg" keep their comma).
    comma = next((i for i, ch in enumerate(remainder)
                  if ch == "," and not (i + 1 < len(remainder) and remainder[i + 1].isnumeric())), -1)
    if comma >= 0:
        tail = collapse_whitespace(remainder[comma + 1:])
        comma_note = tail or None
        remainder = remainder[:comma]

    name = collapse_whitespace(remainder)
    # Swift: look past a leading article ("a large onion") — it only reads as a
    # quantity before a unit, so it can still be sitting in front of the size word.
    after_article = _dropping_leading_word("a", name)
    if after_article is None:
        after_article = _dropping_leading_word("an", name)
    size_base = after_article if after_article is not None else name
    size_note = _leading_size_word(size_base)
    if size_note is not None:
        name = collapse_whitespace(size_base[len(size_note):])
    prep_note = _trailing_prep_phrase(name)
    if prep_note is not None:
        name = collapse_whitespace(name[: len(name) - len(prep_note)])
    without_of = _dropping_leading_word("of", name)
    if without_of is not None:
        name = without_of

    note_parts.extend(p for p in (range_note, size_note, prep_note, comma_note) if p)
    note = ", ".join(note_parts) if note_parts else None

    is_unresolved = False
    if not name:
        # §7.2: "If nothing is left, the line is unresolved with name = raw_line."
        is_unresolved = True
        name = stripped
    return {
        "rawLine": raw_line,
        "quantity": quantity,
        "quantityText": quantity_text,
        "unitKey": unit_key,
        "unitText": unit_text,
        "name": name,
        "note": note,
        "isUnresolved": is_unresolved,
    }


# ---------------------------------------------------------------------------
# Model/FuzzyMatch.swift
# ---------------------------------------------------------------------------

def fuzzy_tokens(text: str) -> list[str]:
    """Swift `FuzzyMatch.tokens`: `lowercased().split { !($0.isLetter || $0.isNumber) }`."""
    out: list[str] = []
    current: list[str] = []
    for ch in text.lower():
        if ch.isalpha() or unicodedata.category(ch).startswith("N"):
            current.append(ch)
        elif current:
            out.append("".join(current))
            current = []
    if current:
        out.append("".join(current))
    return out


def jaro(a: str, b: str) -> float:
    """Swift `FuzzyMatch.jaro` (Jaro 1989). Two empty strings are not a match."""
    if a == b:
        return 0.0 if not a else 1.0
    s1, s2 = list(a), list(b)
    if not s1 or not s2:
        return 0.0
    match_distance = max(max(len(s1), len(s2)) // 2 - 1, 0)
    s1_matched = [False] * len(s1)
    s2_matched = [False] * len(s2)
    matches = 0
    for i in range(len(s1)):
        lo = max(0, i - match_distance)
        hi = min(i + match_distance + 1, len(s2))
        for j in range(lo, hi):
            if not s2_matched[j] and s2[j] == s1[i]:
                s1_matched[i] = True
                s2_matched[j] = True
                matches += 1
                break
    if matches == 0:
        return 0.0
    transpositions = 0
    k = 0
    for i in range(len(s1)):
        if not s1_matched[i]:
            continue
        while not s2_matched[k]:
            k += 1
        if s1[i] != s2[k]:
            transpositions += 1
        k += 1
    m = float(matches)
    half_transpositions = transpositions / 2.0
    return (m / len(s1) + m / len(s2) + (m - half_transpositions) / m) / 3


def jaro_winkler(a: str, b: str) -> float:
    """Swift `FuzzyMatch.jaroWinkler` (Winkler 1990): up to a 4-character prefix bonus."""
    j = jaro(a, b)
    prefix = 0
    for x, y in zip(a, b):
        if x == y and prefix < 4:
            prefix += 1
        else:
            break
    return j + prefix * 0.1 * (1 - j)


def directed_token_similarity(query: str, candidate: str) -> float:
    """Swift `FuzzyMatch.directedTokenSimilarity`: average over the *query's* tokens of the
    best Jaro–Winkler among the candidate's (the workout app's one-directional metric)."""
    query_tokens, candidate_tokens = fuzzy_tokens(query), fuzzy_tokens(candidate)
    if not query_tokens or not candidate_tokens:
        return 0.0
    total = sum(max(jaro_winkler(q, c) for c in candidate_tokens) for q in query_tokens)
    return total / len(query_tokens)


def token_similarity(a: str, b: str) -> float:
    """Swift `FuzzyMatch.tokenSimilarity`: the minimum of both directions, so neither
    side's extra words are free ("cream" vs "sour cream" = 0.5)."""
    return min(directed_token_similarity(a, b), directed_token_similarity(b, a))


def similarity(query: str, candidate: str) -> float:
    """Swift `FuzzyMatch.similarity`: both sides normalized (§7.1); the whole-string
    Jaro–Winkler is consulted ONLY when both sides have the same number of tokens, so a
    short query that is a prefix of a longer name cannot ride the prefix bonus."""
    q, c = normalize(query), normalize(candidate)
    if not q or not c:
        return 0.0
    if q == c:
        return 1.0
    token_score = token_similarity(q, c)
    if len(fuzzy_tokens(q)) == len(fuzzy_tokens(c)):
        score = max(jaro_winkler(q, c), token_score)
    else:
        score = token_score
    # Two ingredient names are at most as similar as their head nouns: a shared
    # modifier ("grated gruyere" vs the alias "grated nutmeg") must not carry a match.
    qh, ch = fuzzy_tokens(q), fuzzy_tokens(c)
    if not qh or not ch:
        return score
    return min(score, jaro_winkler(qh[-1], ch[-1]))


# ---------------------------------------------------------------------------
# Parsing/IngredientIndex.swift + Parsing/IngredientResolver.swift
# ---------------------------------------------------------------------------

# IngredientResolver.defaultFuzzyThreshold / alternativesLimit. Layer 3 (embeddings) is off
# here, exactly as GoldenCorpusTests scores it — the path every device has (§7.6).
DEFAULT_FUZZY_THRESHOLD = 0.86
ALTERNATIVES_LIMIT = 3


def exact_key(name: str) -> str:
    """Swift `IngredientIndex.exactKey`: whitespace-collapsed, lowercased."""
    return " ".join(name.split()).lower()


class IngredientIndex:
    """Swift `IngredientIndex`: the three deterministic lookup tables over a snapshot of the
    registry. A loose key two *different* ingredients share is ambiguous and yields nothing,
    so no layer ever auto-merges two canonicals (§7.4)."""

    def __init__(self, entries: list[dict]) -> None:
        # entries: [{"id": int, "canonicalName": str, "aliases": [normalized alias]}]
        self.entries = entries
        self._by_id: dict[int, dict] = {}
        self._by_exact_name: dict[str, int] = {}
        self._by_alias: dict[str, int] = {}
        self._by_loose_key: dict[str, int] = {}
        ambiguous: set[str] = set()
        for entry in entries:
            if entry["id"] not in self._by_id:
                self._by_id[entry["id"]] = entry
            key = exact_key(entry["canonicalName"])
            if key and key not in self._by_exact_name:
                self._by_exact_name[key] = entry["id"]
            for alias in entry["aliases"]:
                if alias and alias not in self._by_alias:
                    self._by_alias[alias] = entry["id"]
            for text in [entry["canonicalName"]] + list(entry["aliases"]):
                loose = loose_key(text)
                if not loose:
                    continue
                owner = self._by_loose_key.get(loose)
                if owner is not None:
                    if owner != entry["id"]:
                        ambiguous.add(loose)
                else:
                    self._by_loose_key[loose] = entry["id"]
        for key in ambiguous:
            self._by_loose_key.pop(key, None)

    def entry(self, ingredient_id: int) -> dict | None:
        return self._by_id.get(ingredient_id)

    def exact_match(self, name: str) -> int | None:
        """Layer 0."""
        key = exact_key(name)
        return self._by_exact_name.get(key) if key else None

    def alias_match(self, name: str) -> int | None:
        """Layer 1."""
        key = normalize(name)
        return self._by_alias.get(key) if key else None

    def loose_match(self, name: str) -> int | None:
        """Layer 1.5."""
        key = loose_key(name)
        return self._by_loose_key.get(key) if key else None


class IngredientResolver:
    """Swift `IngredientResolver`, layers 0 → 1 → 1.5 → 2 (first hit wins). Layer 3 needs
    NaturalLanguage and is off; layer 4 needs the model's `canonicalGuess`, which the corpus
    does not carry. Every layer ≥ 2 only *proposes*; the corpus scores the proposal."""

    def __init__(self, index: IngredientIndex, fuzzy_threshold: float = DEFAULT_FUZZY_THRESHOLD) -> None:
        self.index = index
        self.fuzzy_threshold = fuzzy_threshold

    def resolve_deterministic(self, name: str) -> tuple[int, str, float] | None:
        """Swift `resolveDeterministic`: (id, resolution, score) for layers 0–1.5."""
        trimmed = name.strip()
        if not trimmed:
            return None
        found = self.index.exact_match(trimmed)
        if found is not None:
            return found, "exact", 1.0
        found = self.index.alias_match(trimmed)
        if found is not None:
            return found, "alias", 1.0
        found = self.index.loose_match(trimmed)
        if found is not None:
            return found, "loose", 1.0
        return None

    def fuzzy_suggestions(self, name: str, limit: int = ALTERNATIVES_LIMIT) -> list[tuple[int, str, float]]:
        """Swift `fuzzySuggestions`: candidates ≥ threshold scored as the best of canonical
        name and aliases, sorted score desc, then closest canonical length, then name."""
        if limit <= 0:
            return []
        query = name.strip()
        if not normalize(query):
            return []
        found: list[tuple[int, str, float]] = []
        for entry in self.index.entries:
            best = similarity(query, entry["canonicalName"])
            for alias in entry["aliases"]:
                best = max(best, similarity(query, alias))
            if best >= self.fuzzy_threshold:
                found.append((entry["id"], entry["canonicalName"], best))
        query_length = len(query)
        found.sort(key=lambda c: (-c[2], abs(len(c[1]) - query_length), c[1]))
        return found[:limit]

    def resolve(self, name: str) -> tuple[int, str, float] | None:
        """Swift `resolve(_:)`, hit only: layers 0–1.5, then the best fuzzy candidate."""
        deterministic = self.resolve_deterministic(name)
        if deterministic is not None:
            return deterministic
        fuzzy = self.fuzzy_suggestions(name, limit=ALTERNATIVES_LIMIT + 1)
        if fuzzy:
            ingredient_id, _, score = fuzzy[0]
            return ingredient_id, "fuzzy", score
        return None


def load_seed(path: Path) -> list[dict]:
    """The bundled seed as a list of SeedIngredient dictionaries."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SystemExit(f"FAILED — cannot read {path}: {exc}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"FAILED — {path.name} is not valid JSON: {exc}")
    if not isinstance(data, list) or not data:
        raise SystemExit(f"FAILED — {path.name} must be a non-empty JSON array")
    return data


def index_from_seed(seeds: list[dict]) -> tuple[IngredientIndex, dict[int, str]]:
    """GoldenCorpusTests.makeSeedIndex: synthetic ids 1…n in file order, aliases normalized
    exactly as `seedIngredientsIfNeeded` stores them, plus id → slug for scoring."""
    entries: list[dict] = []
    slug_by_id: dict[int, str] = {}
    for offset, seed in enumerate(seeds):
        ingredient_id = offset + 1
        entries.append({
            "id": ingredient_id,
            "canonicalName": seed["canonical_name"],
            "category": seed["category"],
            "aliases": [normalize(alias) for alias in seed["aliases"]],
        })
        slug_by_id[ingredient_id] = seed["slug"]
    return IngredientIndex(entries), slug_by_id


# ---------------------------------------------------------------------------
# Scoring — the same comparison GoldenCorpusTests.swift makes
# ---------------------------------------------------------------------------

def _collapsed(text: str) -> str:
    """GoldenCorpusTests.collapsed: whitespace-collapsed and lowercased."""
    return " ".join(text.split()).lower()


def _same_optional_text(a: str | None, b: str | None) -> bool:
    if a is None and b is None:
        return True
    if a is None or b is None:
        return False
    return _collapsed(a) == _collapsed(b)


def _same_quantity(a: float | None, b: float | None) -> bool:
    if a is None and b is None:
        return True
    if a is None or b is None:
        return False
    return abs(a - b) <= 1e-6


def splitter_matches(actual: dict, expected: dict) -> bool:
    """GoldenCorpusTests.splitterMatches."""
    return (_same_quantity(actual["quantity"], expected.get("quantity"))
            and actual["unitKey"] == expected.get("unit_key")
            and _collapsed(actual["name"]) == _collapsed(expected.get("name") or expected["line"])
            and _same_optional_text(actual["note"], expected.get("note")))


def score(fixture: dict, resolver: IngredientResolver, slug_by_id: dict[int, str]) -> dict:
    """Both pass rates plus every mismatch, in fixture order."""
    lines = fixture["lines"]
    splitter_passes = 0
    resolution_passes = 0
    splitter_misses: list[str] = []
    resolution_misses: list[str] = []
    for expected in lines:
        structured = split(expected["line"])
        if splitter_matches(structured, expected):
            splitter_passes += 1
        else:
            splitter_misses.append(
                f"{expected['line']!r}\n"
                f"    got      quantity={structured['quantity']!r} unit={structured['unitKey']!r} "
                f"name={structured['name']!r} note={structured['note']!r}\n"
                f"    expected quantity={expected.get('quantity')!r} unit={expected.get('unit_key')!r} "
                f"name={(expected.get('name') or expected['line'])!r} note={expected.get('note')!r}")
        hit = resolver.resolve(structured["name"])
        actual_slug = slug_by_id.get(hit[0]) if hit else None
        if actual_slug == expected.get("slug"):
            resolution_passes += 1
        else:
            layer = hit[1] if hit else "none"
            score_text = f"{hit[2]:.4f}" if hit else "-"
            resolution_misses.append(
                f"{expected['line']!r} → name {structured['name']!r}\n"
                f"    got {actual_slug!r} via {layer} ({score_text}), expected {expected.get('slug')!r}")
    total = max(len(lines), 1)
    return {
        "total": len(lines),
        "splitter_passes": splitter_passes,
        "resolution_passes": resolution_passes,
        "splitter_rate": splitter_passes / total,
        "resolution_rate": resolution_passes / total,
        "splitter_misses": splitter_misses,
        "resolution_misses": resolution_misses,
    }


def report(fixture_path: Path, seed_path: Path, show_misses: bool = True) -> int:
    """Print the mismatches and the two pass rates; 1 when either is below the baseline."""
    try:
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise SystemExit(f"FAILED — cannot read {fixture_path}: {exc}")
    except json.JSONDecodeError as exc:
        raise SystemExit(f"FAILED — {fixture_path.name} is not valid JSON: {exc}")
    if not isinstance(fixture, dict) or "lines" not in fixture or "baseline" not in fixture:
        raise SystemExit(f"FAILED — {fixture_path.name} must be an object with 'baseline' and 'lines'")

    index, slug_by_id = index_from_seed(load_seed(seed_path))
    resolver = IngredientResolver(index)
    result = score(fixture, resolver, slug_by_id)

    if show_misses:
        for miss in result["splitter_misses"]:
            print(f"[splitter miss] {miss}")
        for miss in result["resolution_misses"]:
            print(f"[resolution miss] {miss}")

    baseline = fixture["baseline"]
    splitter_baseline = float(baseline.get("splitter", 0))
    resolution_baseline = float(baseline.get("resolution", 0))
    total = result["total"]
    print(f"[reference_parser] splitter   {result['splitter_passes']}/{total} = "
          f"{result['splitter_rate'] * 100:.2f}% (baseline {splitter_baseline * 100:.2f}%, "
          f"{len(result['splitter_misses'])} misses)")
    print(f"[reference_parser] resolution {result['resolution_passes']}/{total} = "
          f"{result['resolution_rate'] * 100:.2f}% (baseline {resolution_baseline * 100:.2f}%, "
          f"{len(result['resolution_misses'])} misses)")

    failed = False
    if result["splitter_rate"] + 1e-9 < splitter_baseline:
        print("FAILED — splitter pass rate is below the fixture baseline")
        failed = True
    if result["resolution_rate"] + 1e-9 < resolution_baseline:
        print("FAILED — resolution pass rate is below the fixture baseline")
        failed = True
    return 1 if failed else 0


def explain(line: str, seed_path: Path) -> None:
    """One line through the whole pipeline, for authoring the corpus."""
    index, slug_by_id = index_from_seed(load_seed(seed_path))
    resolver = IngredientResolver(index)
    structured = split(line)
    hit = resolver.resolve(structured["name"])
    print(f"line       {line!r}")
    print(f"stripped   {strip_bullet(line)!r}  header={is_section_header(strip_bullet(line))}")
    print(f"quantity   {structured['quantity']!r}  text={structured['quantityText']!r}")
    print(f"unit       {structured['unitKey']!r}  text={structured['unitText']!r}")
    print(f"name       {structured['name']!r}  unresolved={structured['isUnresolved']}")
    print(f"note       {structured['note']!r}")
    if hit is None:
        print("slug       None (nothing hit at layers 0–2)")
        for candidate in resolver.fuzzy_suggestions(structured["name"], limit=3):
            print(f"           near miss {candidate[1]!r} {candidate[2]:.4f}")
    else:
        print(f"slug       {slug_by_id[hit[0]]!r} via {hit[1]} ({hit[2]:.4f}) "
              f"→ {index.entry(hit[0])['canonicalName']!r}")


# ---------------------------------------------------------------------------
# Self-test — the Swift authors' designed cases
# ---------------------------------------------------------------------------

# The cases IngredientLineSplitterTests and QuantityParserTests pin, in the same
# shape: (line, quantity, unit_key, name, note).
SPLITTER_CASES: tuple[tuple[str, float | None, str | None, str, str | None], ...] = (
    ("2 cups vegetable broth", 2.0, "cup", "vegetable broth", None),
    ("1 1/2 tsp. kosher salt", 1.5, "tsp", "kosher salt", None),
    ("½ cup heavy cream", 0.5, "cup", "heavy cream", None),
    ("1 (14.5 oz) can diced tomatoes", 1.0, "can", "diced tomatoes", "14.5 oz"),
    ("2–3 tablespoons olive oil, divided", 2.0, "tbsp", "olive oil", "2–3, divided"),
    ("a pinch of nutmeg", 1.0, "pinch", "nutmeg", None),
    ("one large onion, diced", 1.0, None, "onion", "large, diced"),
    ("500ml chicken stock", 500.0, "ml", "chicken stock", None),
    ("2 T soy sauce", 2.0, "tbsp", "soy sauce", None),
    ("1 t vanilla extract", 1.0, "tsp", "vanilla extract", None),
    ("Juice of 1 lemon", None, None, "Juice of 1 lemon", None),
    ("Salt and pepper to taste", None, None, "Salt and pepper", "to taste"),
    ("3 cloves garlic, minced", 3.0, "clove", "garlic", "minced"),
    ("2cups flour", 2.0, "cup", "flour", None),
    ("- 2 cups all-purpose flour", 2.0, "cup", "all-purpose flour", None),
    ("1. 2 cups sugar", 2.0, "cup", "sugar", None),
    ("1.5 cups sugar", 1.5, "cup", "sugar", None),
    ("1½ cups milk", 1.5, "cup", "milk", None),
    ("1 ½ cups milk", 1.5, "cup", "milk", None),
    ("1-1/2 cups milk", 1.5, "cup", "milk", None),
    ("2 to 3 cups spinach", 2.0, "cup", "spinach", "2 to 3"),
    ("2 or 3 lemons", 2.0, None, "lemons", "2 or 3"),
    ("2 - 3 lemons", 2.0, None, "lemons", "2 - 3"),
    ("10-inch flour tortillas", None, None, "10-inch flour tortillas", None),
    ("2% milk", None, None, "2% milk", None),
    ("1 cup walnuts (optional)", 1.0, "cup", "walnuts", "optional"),
    ("2 tbsp butter, melted (optional)", 2.0, "tbsp", "butter", "optional, melted"),
    ("1 large egg", 1.0, None, "egg", "large"),
    ("Large eggs", None, None, "eggs", "Large"),
    ("2 cups", 2.0, "cup", "2 cups", None),
    ("", None, None, "", None),
    ("For the sauce:", None, None, "For the sauce:", None),
    ("1 cup of sugar", 1.0, "cup", "sugar", None),
    ("3 Tomatoes", 3.0, None, "Tomatoes", None),
    ("1 whole chicken", 1.0, "piece", "chicken", None),
    ("2 tsp fresh thyme, finely chopped", 2.0, "tsp", "fresh thyme", "finely chopped"),
    ("1 onion thinly sliced", 1.0, None, "onion", "thinly sliced"),
    ("Salt, plus more for seasoning", None, None, "Salt", "plus more for seasoning"),
    ("2 tbsp olive oil plus more for frying", 2.0, "tbsp", "olive oil", "plus more for frying"),
    ("4 fl oz milk", 4.0, "floz", "milk", None),
    ("a fl oz of cream", 1.0, "floz", "cream", None),
    ("an onion", None, None, "an onion", None),
    ("A can of beans", 1.0, "can", "beans", None),
    ("One-pot pasta", None, None, "One-pot pasta", None),
    ("Two eggs", 2.0, None, "eggs", None),
    (".5 cup sugar", 0.5, "cup", "sugar", None),
    ("1/2-inch piece ginger", None, None, "1/2-inch piece ginger", None),
    ("3 large eggs, beaten", 3.0, None, "eggs", "large, beaten"),
    ("• 1 bunch cilantro", 1.0, "bunch", "cilantro", None),
    ("(1) 2 cups rice", 2.0, "cup", "rice", None),
    ("① 1 cup rice", 1.0, "cup", "rice", None),
    ("2 cups flour, sifted, divided", 2.0, "cup", "flour", "sifted, divided"),
    ("1 (about 1 lb) eggplant", 1.0, None, "eggplant", "about 1 lb"),
    ("6-8 cups water", 6.0, "cup", "water", "6-8"),
    ("1 c sugar", 1.0, "cup", "sugar", None),
    ("3 l water", 3.0, "l", "water", None),
    ("3 large potatoes", 3.0, None, "potatoes", "large"),
    ("2 sticks celery", 2.0, "stick", "celery", None),
    ("1 lb. ground beef", 1.0, "lb", "ground beef", None),
    ("1 tsp.salt", 1.0, "tsp", "salt", None),
)

# LineCleanerTests: (line, stripped).
BULLET_CASES: tuple[tuple[str, str], ...] = (
    ("- 2 cups flour", "2 cups flour"),
    ("• salt", "salt"),
    ("1. flour", "flour"),
    ("1) flour", "flour"),
    ("(1) flour", "flour"),
    ("1.5 cups milk", "1.5 cups milk"),
    ("- - salt", "salt"),
    ("—", ""),
    ("* • 3 eggs", "3 eggs"),
    ("☐ 1 lemon", "1 lemon"),
    ("1234. flour", "1234. flour"),
    ("  2 eggs  ", "2 eggs"),
    ("① 1 cup rice", "1 cup rice"),
)

HEADER_CASES: tuple[tuple[str, bool], ...] = (
    ("For the sauce:", True),
    ("Ingredients:", True),
    ("2 cups:", False),
    ("Salt", False),
    ("½ cup:", False),
    ("For the topping", False),
)

# UnitTableTests: (spelling, key).
UNIT_SPELLING_CASES: tuple[tuple[str, str | None], ...] = (
    ("T", "tbsp"), ("t", "tsp"), ("T.", "tbsp"), ("Tbsp", "tbsp"), ("TSP", "tsp"),
    ("Cups", "cup"), ("tsp.", "tsp"), ("oz..", "oz"), (" lb ", "lb"),
    ("fl oz", "floz"), ("fl. oz", "floz"), ("qt", "quart"), ("pt", "pint"),
    ("gal", "gallon"), ("rib", "stalk"), ("handful", "handful"), ("dash", "dash"),
    ("", None), (".", None), ("large", None), ("of", None), ("onion", None), ("eggs", None),
)

# UnitTableTests.longestMatch: (text, key, matchedText).
UNIT_MATCH_CASES: tuple[tuple[str, str | None, str | None], ...] = (
    ("cups flour", "cup", "cups"),
    ("fl oz milk", "floz", "fl oz"),
    ("tablespoons butter", "tbsp", "tablespoons"),
    ("large eggs", None, None),
    ("Tomatoes", None, None),
    ("cupsful", None, None),
    ("l water", "l", "l"),
    ("tsp. salt", "tsp", "tsp"),
    ("cup, sifted", "cup", "cup"),
    ("oz) can", "oz", "oz"),
    ("cup", "cup", "cup"),
    ("Tbsp. oil", "tbsp", "Tbsp"),
    ("T soy sauce", "tbsp", "T"),
    ("t vanilla", "tsp", "t"),
    ("C flour", "cup", "C"),
    ("L milk", "l", "L"),
    ("   cup sugar", "cup", "cup"),
    ("", None, None),
    ("   ", None, None),
)

# FuzzyMatchTests: every number asserted there, computed with the port first.
FUZZY_VALUE_CASES: tuple[tuple[str, float], ...] = (
    ("jaro('martha','marhta')", 0.9444),
    ("jaro('dixon','dicksonx')", 0.7667),
    ("jaroWinkler('martha','marhta')", 0.9611),
    ("jaroWinkler('dixon','dicksonx')", 0.8133),
    ("jaroWinkler('tomatos','tomato')", 0.9714),
    ("similarity('cream','Sour cream')", 0.5),
    ("similarity('chicken','Chicken broth')", 0.0),
    ("similarity('garlic','Garlic powder')", 0.0),
    ("similarity('smoked paprika','Paprika')", 0.7183),
    ("similarity('brown sugar','Sugar')", 0.5),
    ("similarity('veggie broth','Vegetable broth')", 0.8963),
    ("similarity('bell peper','Bell pepper')", 0.9611),
    ("similarity('mozzarela','Mozzarella')", 0.98),
    ("similarity('chiken','Chicken')", 0.9667),
    ("similarity('asdfqwer','Bell pepper')", 0.2639),
    ("similarity('ice cream','Cream')", 0.8444),
    ("similarity('baking soda','Baking powder')", 0.6111),
)


def _fuzzy_value(name: str) -> float:
    """Evaluate one FUZZY_VALUE_CASES label — the labels are the Swift call sites."""
    head, args = name.split("(", 1)
    a, b = [part.strip().strip("'") for part in args.rstrip(")").split("','")]
    return {"jaro": jaro, "jaroWinkler": jaro_winkler, "similarity": similarity}[head](a, b)


def selftest() -> int:
    """Run every designed case the Swift authors pinned. Loud on any drift."""
    failures: list[str] = []

    for line, expected in BULLET_CASES:
        got = strip_bullet(line)
        if got != expected:
            failures.append(f"strip_bullet({line!r}) = {got!r}, expected {expected!r}")
    for line, expected_header in HEADER_CASES:
        got_header = is_section_header(line)
        if got_header != expected_header:
            failures.append(f"is_section_header({line!r}) = {got_header}, expected {expected_header}")
    for spelling, expected_key in UNIT_SPELLING_CASES:
        got_key = key_for_spelling(spelling)
        if got_key != expected_key:
            failures.append(f"key_for_spelling({spelling!r}) = {got_key!r}, expected {expected_key!r}")
    for text, expected_key, expected_text in UNIT_MATCH_CASES:
        match = longest_unit_match(text)
        got = (match[0], match[1]) if match else (None, None)
        if got != (expected_key, expected_text):
            failures.append(f"longest_unit_match({text!r}) = {got!r}, expected {(expected_key, expected_text)!r}")

    for line, quantity, unit, name, note in SPLITTER_CASES:
        result = split(line)
        if not _same_quantity(result["quantity"], quantity):
            failures.append(f"split({line!r}).quantity = {result['quantity']!r}, expected {quantity!r}")
        if result["unitKey"] != unit:
            failures.append(f"split({line!r}).unitKey = {result['unitKey']!r}, expected {unit!r}")
        if result["name"].lower() != name.lower():
            failures.append(f"split({line!r}).name = {result['name']!r}, expected {name!r}")
        if result["note"] != note:
            failures.append(f"split({line!r}).note = {result['note']!r}, expected {note!r}")

    # FuzzyMatchTests' exact values (accuracy 0.001, as asserted there).
    for label, expected_value in FUZZY_VALUE_CASES:
        got_value = _fuzzy_value(label)
        if abs(got_value - expected_value) > 0.001:
            failures.append(f"{label} = {got_value:.4f}, expected {expected_value}")
    # FuzzyMatchTests' structural assertions.
    structural: tuple[tuple[str, bool], ...] = (
        ("jaro('abc','abc') == 1", jaro("abc", "abc") == 1),
        ("jaro('abc','xyz') == 0", jaro("abc", "xyz") == 0),
        ("jaro('','') == 0", jaro("", "") == 0),
        ("jaro('','abc') == 0", jaro("", "abc") == 0),
        ("jaroWinkler('bench','bench') == 1", jaro_winkler("bench", "bench") == 1),
        ("jaroWinkler('asdf','bench') == 0", jaro_winkler("asdf", "bench") == 0),
        ("tokens('Bell-Pepper, red')", fuzzy_tokens("Bell-Pepper, red") == ["bell", "pepper", "red"]),
        ("tokens('  ')", fuzzy_tokens("  ") == []),
        ("tokens('2% milk')", fuzzy_tokens("2% milk") == ["2", "milk"]),
        ("directed('cream','sour cream') == 1",
         abs(directed_token_similarity("cream", "sour cream") - 1.0) < 1e-9),
        ("directed('sour cream','cream') == 0.5",
         abs(directed_token_similarity("sour cream", "cream") - 0.5) < 1e-9),
        ("tokenSimilarity is symmetric",
         token_similarity("sour cream", "cream") == token_similarity("cream", "sour cream")),
        ("tokenSimilarity('','cream') == 0", token_similarity("", "cream") == 0),
        ("similarity('tomatos','Tomato') == 1", similarity("tomatos", "Tomato") == 1),
        ("similarity('scallions','Scallion') == 1", similarity("scallions", "Scallion") == 1),
        ("similarity('all purpose flour','All-purpose flour') == 1",
         similarity("all purpose flour", "All-purpose flour") == 1),
        ("similarity('','Onion') == 0", similarity("", "Onion") == 0),
        ("similarity('   ','Onion') == 0", similarity("   ", "Onion") == 0),
        ("similarity('(note only)','Onion') == 0", similarity("(note only)", "Onion") == 0),
        # The substring traps stay under the threshold; the real variants clear it.
        ("cream/Sour cream < the threshold", similarity("cream", "Sour cream") < DEFAULT_FUZZY_THRESHOLD),
        ("chicken/Chicken broth < the threshold", similarity("chicken", "Chicken broth") < DEFAULT_FUZZY_THRESHOLD),
        ("Chicken Broth/Chicken < the threshold", similarity("Chicken Broth", "Chicken") < DEFAULT_FUZZY_THRESHOLD),
        ("garlic clove/Garlic < the threshold", similarity("garlic clove", "Garlic") < DEFAULT_FUZZY_THRESHOLD),
        ("red onion/Onion < the threshold", similarity("red onion", "Onion") < DEFAULT_FUZZY_THRESHOLD),
        ("green onions/Onion < the threshold", similarity("green onions", "Onion") < DEFAULT_FUZZY_THRESHOLD),
        ("smoked paprika/Paprika < the threshold", similarity("smoked paprika", "Paprika") < DEFAULT_FUZZY_THRESHOLD),
        ("brown sugar/Sugar < the threshold", similarity("brown sugar", "Sugar") < DEFAULT_FUZZY_THRESHOLD),
        ("cilantro/Coriander < the threshold", similarity("cilantro", "Coriander") < DEFAULT_FUZZY_THRESHOLD),
        ("veggie broth/Vegetable broth >= the threshold",
         similarity("veggie broth", "Vegetable broth") >= DEFAULT_FUZZY_THRESHOLD),
        ("veggie stock/Vegetable stock >= the threshold",
         similarity("veggie stock", "Vegetable stock") >= DEFAULT_FUZZY_THRESHOLD),
        ("greek yoghurt/Greek yogurt >= the threshold",
         similarity("greek yoghurt", "Greek yogurt") >= DEFAULT_FUZZY_THRESHOLD),
        ("qwertyuiop/Olive oil < 0.6", similarity("qwertyuiop", "Olive oil") < 0.6),
        # The word-count gate itself.
        ("same word count uses the whole-string score, capped by the head nouns",
         abs(similarity("bell peper", "Bell pepper") - jaro_winkler("peper", "pepper")) < 1e-9),
        ("different word counts never exceed the token metric",
         similarity("chicken", "Chicken broth") <= token_similarity("chicken", "chicken broth") + 1e-9),
        ("a shared modifier does not carry a match",
         similarity("grated gruyere", "grated nutmeg") < DEFAULT_FUZZY_THRESHOLD
         and similarity("shredded carot", "shredded cheddar") < DEFAULT_FUZZY_THRESHOLD),
        ("similarity is symmetric",
         all(abs(similarity(a, b) - similarity(b, a)) < 1e-9
             for a, b in (("veggie broth", "Vegetable broth"), ("chicken", "Chicken broth"),
                          ("mozzarela", "Mozzarella")))),
    )
    for label, ok in structural:
        if not ok:
            failures.append(f"{label} — false")

    if failures:
        print("FAILED — reference_parser.py drifted from the Swift grammar:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    checks = (len(BULLET_CASES) + len(HEADER_CASES) + len(UNIT_SPELLING_CASES)
              + len(UNIT_MATCH_CASES) + 4 * len(SPLITTER_CASES) + len(FUZZY_VALUE_CASES)
              + len(structural))
    print(f"reference_parser.py: {checks} designed cases OK "
          f"({len(SPLITTER_CASES)} splitter lines, {len(FUZZY_VALUE_CASES)} pinned similarity values)")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Score the golden corpus against the Python mirror of the Swift parser.")
    parser.add_argument("fixture", nargs="?", type=Path, default=None,
                        help=f"corpus fixture (default {DEFAULT_FIXTURE.relative_to(REPO_ROOT)})")
    parser.add_argument("--seed", type=Path, default=DEFAULT_SEED,
                        help="bundled seed_ingredients.json")
    parser.add_argument("--selftest", action="store_true",
                        help="run the designed grammar cases instead of scoring a fixture")
    parser.add_argument("--explain", metavar="LINE", default=None,
                        help="print one line's whole trip through the pipeline")
    parser.add_argument("--quiet", action="store_true", help="pass rates only, no mismatches")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()
    if args.explain is not None:
        explain(args.explain, args.seed)
        return 0
    return report(args.fixture or DEFAULT_FIXTURE, args.seed, show_misses=not args.quiet)


if __name__ == "__main__":
    raise SystemExit(main())
