import Foundation

/// A quantity found at the start of an ingredient line (spec §7.2). `text` is the
/// author's spelling ("1 1/2", "½", "2–3", "one"), kept so Confirm can show what was
/// read; `rangeText` is set only for a range, whose `value` is the lower bound and
/// whose text goes into the row's note ("2–3").
struct ParsedQuantity: Equatable, Sendable {
    let value: Double
    let text: String
    let rangeText: String?

    init(value: Double, text: String, rangeText: String? = nil) {
        self.value = value
        self.text = text
        self.rangeText = rangeText
    }
}

/// The quantity grammar of the regex splitter (§7.2), written as a hand scanner over
/// `Character`s rather than a regular expression so vulgar fractions, en dashes and
/// case-sensitive follow-on units ("2T") are handled exactly and readably. Pure.
///
/// Accepted at the start of the text: integers, decimals ("1.5", ".5"), ASCII
/// fractions ("1/2", also U+2044), mixed numbers ("1 1/2", "1-1/2", "1½", "1 ½"),
/// Unicode vulgar fractions alone, ranges ("2-3", "2–3", "2 to 3", "2 or 3" — value
/// is the lower bound), the number words "one"…"twelve" (only when followed by
/// whitespace) and "a"/"an" when the next word is a unit spelling ("a pinch" → 1).
///
/// A number must end at a boundary: end of text, whitespace, a letter (a glued unit
/// like "500ml" — the remainder then starts at "ml"), "(" or ",". Anything else
/// ("10-inch", "2%", "1/2-inch") means the line does not start with a quantity, and
/// the whole text stays the name — a wrong quantity is worse than none (§1).
///
/// Mirrors the workout app's deterministic-first posture. The Python port that fixed
/// these ordering rules is committed as `scripts/reference_parser.py`; its
/// `--selftest` replays sixty splitter lines, so a change here that the tests miss
/// still has somewhere to fail.
enum QuantityParser {
    /// "one"…"twelve" (§7.2). Deliberately no "half"/"dozen": "half an onion" is a
    /// prep note, not a countable quantity, and inventing 0.5 would be a wrong number.
    static let numberWords: [String: Double] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    /// Unicode vulgar fractions the grammar understands, alone or after an integer.
    static let vulgarFractions: [Character: Double] = [
        "½": 1.0 / 2.0, "⅓": 1.0 / 3.0, "⅔": 2.0 / 3.0, "¼": 1.0 / 4.0, "¾": 3.0 / 4.0,
        "⅛": 1.0 / 8.0, "⅜": 3.0 / 8.0, "⅝": 5.0 / 8.0, "⅞": 7.0 / 8.0,
        "⅕": 1.0 / 5.0, "⅖": 2.0 / 5.0, "⅗": 3.0 / 5.0, "⅘": 4.0 / 5.0, "⅙": 1.0 / 6.0, "⅚": 5.0 / 6.0,
    ]

    /// Separators accepted inside a numeric range: hyphen, en dash, em dash, figure
    /// dash and the minus sign (what word processors and OCR substitute for "-").
    static let rangeDashes: Set<Character> = ["-", "–", "—", "‒", "−"]

    /// Word separators of a range ("2 to 3", "2 or 3"). Need whitespace on both sides.
    static let rangeWords: [String] = ["to", "or"]

    static func value(ofVulgarFraction c: Character) -> Double? {
        vulgarFractions[c]
    }

    /// The quantity at the start of `text` and the text after it (leading whitespace
    /// removed), or nil when the text does not begin with a quantity.
    static func parse(leading text: String) -> (quantity: ParsedQuantity, remainder: String)? {
        let chars = Array(text)
        var start = 0
        while start < chars.count, chars[start].isWhitespace { start += 1 }
        guard start < chars.count else { return nil }

        if let number = scanNumber(chars, at: start) {
            var end = number.end
            var rangeText: String? = nil
            if let rangeEnd = scanRangeTail(chars, from: end) {
                end = rangeEnd
                rangeText = String(chars[start..<end])
            }
            guard isBoundary(chars, at: end) else { return nil }
            let quantity = ParsedQuantity(value: number.value, text: String(chars[start..<end]), rangeText: rangeText)
            return (quantity: quantity, remainder: remainder(chars, from: end))
        }

        // Number words and articles are whole words followed by whitespace, so
        // "One-pot" and "Onion" never read as "one".
        let word = scanWord(chars, at: start)
        guard word.end < chars.count, chars[word.end].isWhitespace else { return nil }
        let lowered = word.text.lowercased()
        if let value = numberWords[lowered] {
            return (quantity: ParsedQuantity(value: value, text: word.text), remainder: remainder(chars, from: word.end))
        }
        if lowered == "a" || lowered == "an", nextTokenIsUnit(chars, from: word.end) {
            return (quantity: ParsedQuantity(value: 1, text: word.text), remainder: remainder(chars, from: word.end))
        }
        return nil
    }

    // MARK: - Scanner

    private struct Scan {
        let value: Double
        let end: Int
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    private static func isFractionSlash(_ c: Character) -> Bool {
        c == "/" || c == "⁄"
    }

    /// Index just past the run of ASCII digits starting at `i`.
    private static func scanDigits(_ chars: [Character], from i: Int) -> Int {
        var j = i
        while j < chars.count, isASCIIDigit(chars[j]) { j += 1 }
        return j
    }

    private static func number(_ chars: [Character], _ range: Range<Int>) -> Double? {
        Double(String(chars[range]))
    }

    /// One simple or mixed number starting exactly at `i` (no leading whitespace).
    private static func scanNumber(_ chars: [Character], at i: Int) -> Scan? {
        let n = chars.count
        guard i < n else { return nil }
        if let fraction = vulgarFractions[chars[i]] {
            return Scan(value: fraction, end: i + 1)
        }
        if chars[i] == ".", i + 1 < n, isASCIIDigit(chars[i + 1]) {
            let j = scanDigits(chars, from: i + 1)
            guard let value = Double("0" + String(chars[i..<j])) else { return nil }
            return Scan(value: value, end: j)
        }
        guard isASCIIDigit(chars[i]) else { return nil }
        let j = scanDigits(chars, from: i)
        guard let whole = number(chars, i..<j) else { return nil }

        // Decimal "1.5"
        if j + 1 < n, chars[j] == ".", isASCIIDigit(chars[j + 1]) {
            let k = scanDigits(chars, from: j + 1)
            guard let value = number(chars, i..<k) else { return nil }
            return Scan(value: value, end: k)
        }
        // ASCII fraction "1/2"
        if j + 1 < n, isFractionSlash(chars[j]), isASCIIDigit(chars[j + 1]) {
            let k = scanDigits(chars, from: j + 1)
            guard let denominator = number(chars, (j + 1)..<k), denominator > 0 else { return nil }
            return Scan(value: whole / denominator, end: k)
        }
        // Glued vulgar fraction "1½"
        if j < n, let fraction = vulgarFractions[chars[j]] {
            return Scan(value: whole + fraction, end: j + 1)
        }
        // Spaced vulgar fraction "1 ½"
        var k = j
        while k < n, chars[k].isWhitespace { k += 1 }
        if k > j, k < n, let fraction = vulgarFractions[chars[k]] {
            return Scan(value: whole + fraction, end: k + 1)
        }
        // Mixed ASCII fraction "1 1/2" or "1-1/2". A hyphen followed by digits with
        // no slash ("2-3") is left for the range scan.
        var fractionStart: Int? = nil
        if k > j, k < n, isASCIIDigit(chars[k]) {
            fractionStart = k
        } else if j + 1 < n, chars[j] == "-", isASCIIDigit(chars[j + 1]) {
            fractionStart = j + 1
        }
        if let f = fractionStart {
            let m = scanDigits(chars, from: f)
            if m + 1 < n, isFractionSlash(chars[m]), isASCIIDigit(chars[m + 1]) {
                let p = scanDigits(chars, from: m + 1)
                if let numerator = number(chars, f..<m), let denominator = number(chars, (m + 1)..<p), denominator > 0 {
                    return Scan(value: whole + numerator / denominator, end: p)
                }
            }
        }
        return Scan(value: whole, end: j)
    }

    /// If a range separator and a second number follow the number ending at `i`,
    /// the index just past that second number; otherwise nil.
    private static func scanRangeTail(_ chars: [Character], from i: Int) -> Int? {
        let n = chars.count
        var j = i
        while j < n, chars[j].isWhitespace { j += 1 }
        guard j < n else { return nil }
        if rangeDashes.contains(chars[j]) {
            var k = j + 1
            while k < n, chars[k].isWhitespace { k += 1 }
            return scanNumber(chars, at: k)?.end
        }
        guard j > i else { return nil }   // "to" / "or" need whitespace before them
        for word in rangeWords {
            let end = j + word.count
            guard end < n, chars[end].isWhitespace else { continue }
            guard String(chars[j..<end]).lowercased() == word else { continue }
            var k = end
            while k < n, chars[k].isWhitespace { k += 1 }
            return scanNumber(chars, at: k)?.end
        }
        return nil
    }

    private static func isBoundary(_ chars: [Character], at i: Int) -> Bool {
        guard i < chars.count else { return true }
        let c = chars[i]
        return c.isWhitespace || c.isLetter || c == "(" || c == ","
    }

    private static func remainder(_ chars: [Character], from i: Int) -> String {
        var j = i
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        return String(chars[j...])
    }

    /// The run of non-whitespace, non-comma characters starting at `i`.
    private static func scanWord(_ chars: [Character], at i: Int) -> (text: String, end: Int) {
        var j = i
        while j < chars.count, !chars[j].isWhitespace, chars[j] != "," { j += 1 }
        return (String(chars[i..<j]), j)
    }

    /// Whether the word (or two words, for "fl oz") after position `i` is a unit
    /// spelling — the only case in which "a"/"an" means 1.
    private static func nextTokenIsUnit(_ chars: [Character], from i: Int) -> Bool {
        var k = i
        while k < chars.count, chars[k].isWhitespace { k += 1 }
        let first = scanWord(chars, at: k)
        guard !first.text.isEmpty else { return false }
        if UnitTable.isSpelling(first.text) { return true }
        var m = first.end
        while m < chars.count, chars[m].isWhitespace { m += 1 }
        let second = scanWord(chars, at: m)
        guard !second.text.isEmpty else { return false }
        return UnitTable.isSpelling(first.text + " " + second.text)
    }
}
