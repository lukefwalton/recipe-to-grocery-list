import Foundation

/// One raw line split into `(quantity, unit, name, note)` by the regex splitter
/// (spec §7.2). `rawLine` is the input exactly as given; `name` keeps the author's
/// casing (the store keeps the name as written; every comparison normalizes).
/// `isUnresolved` means nothing was left for a name and `name` is the whole line.
struct StructuredLine: Equatable, Sendable {
    let rawLine: String
    var quantity: Double?
    /// The quantity as written ("1 1/2", "½", "2–3"), for display.
    var quantityText: String?
    var unitKey: String?
    var unitText: String?
    var name: String
    var note: String?
    var isUnresolved: Bool

    init(rawLine: String,
         quantity: Double? = nil,
         quantityText: String? = nil,
         unitKey: String? = nil,
         unitText: String? = nil,
         name: String,
         note: String? = nil,
         isUnresolved: Bool = false) {
        self.rawLine = rawLine
        self.quantity = quantity
        self.quantityText = quantityText
        self.unitKey = unitKey
        self.unitText = unitText
        self.name = name
        self.note = note
        self.isUnresolved = isUnresolved
    }
}

/// Stage 2 of the pipeline (§7.2): the deterministic splitter that runs on every
/// device; the on-device model only refines its output (§7.3) and can never add or
/// remove a line. Pure, so the golden corpus (§11) can score it directly.
///
/// Order of operations (the implementation contract):
/// 1. strip bullets (`LineCleaner.stripBullet`);
/// 2. pull every `( … )` anywhere in the line into the note ("(optional)" → "optional");
/// 3. quantity at the start (`QuantityParser`);
/// 4. an optional unit right after the quantity (`UnitTable.longestMatch`, no space
///    needed: "500ml"), then a trailing "." and an "of" are skipped;
/// 5. the remainder: text after the FIRST comma is note; a leading size word moves to
///    the note; a trailing prep phrase moves to the note; a leading "of" is dropped;
///    whitespace is collapsed.
///
/// Note pieces are joined with ", " in the order parenthetical(s), range, size, prep,
/// comma text — which is left-to-right order for the ordinary line ("one large
/// onion, diced" → "large, diced"; "2–3 tbsp olive oil, divided" → "2–3, divided").
///
/// Where the contract is silent the simplest deterministic rule wins, and it is
/// written down here so `scripts/reference_parser.py` can mirror it:
/// - a leading size word is stripped whether or not a quantity was found ("Large eggs"
///   → name "eggs", note "Large");
/// - one size word and one trailing prep phrase are moved, longest phrase first;
/// - the unit is only looked for after a quantity ("Pinch of salt" keeps its name);
/// - articles are left in the name ("an onion"); layers 1–1.5 normalize them away;
/// - an unresolved line keeps whatever quantity/unit were read ("2 cups").
enum IngredientLineSplitter {
    /// Prep and usage phrases moved from the end of a name into the note (§7.2 list
    /// plus the contract's additions). Matched case-insensitively as whole trailing
    /// words, longest first, so "thinly sliced" wins over "sliced".
    static let prepWords: [String] = [
        "diced", "minced", "chopped", "sliced", "divided", "to taste", "optional",
        "for serving", "for garnish", "peeled", "crushed", "grated", "shredded", "melted",
        "softened", "beaten", "cubed", "halved", "quartered", "thinly sliced",
        "finely chopped", "roughly chopped", "at room temperature",
    ]

    /// Size words that describe the item, not its identity ("one large onion" is an
    /// onion). Multi-word spellings first so the whole phrase moves.
    static let sizeWords: [String] = ["extra-large", "extra large", "large", "medium", "small", "big"]

    /// An open-ended usage phrase: everything from " plus more" to the end of the name
    /// is note ("olive oil plus more for frying" → "olive oil" / "plus more for frying").
    static let openEndedNoteMarker = "plus more"

    private static let prepWordsLongestFirst: [String] = prepWords.sorted { a, b in
        if a.count != b.count { return a.count > b.count }
        return a < b
    }

    static func split(_ rawLine: String) -> StructuredLine {
        let stripped = LineCleaner.stripBullet(rawLine)
        let extracted = extractParentheticals(stripped)
        var noteParts: [String] = extracted.notes

        var remainder = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var quantity: Double? = nil
        var quantityText: String? = nil
        var rangeNote: String? = nil
        var unitKey: String? = nil
        var unitText: String? = nil

        if let parsed = QuantityParser.parse(leading: remainder) {
            quantity = parsed.quantity.value
            quantityText = parsed.quantity.text
            rangeNote = parsed.quantity.rangeText
            remainder = parsed.remainder
            if let unit = UnitTable.longestMatch(atStartOf: Substring(remainder)) {
                unitKey = unit.key
                unitText = unit.matchedText
                remainder = droppingUnit(unit.matchedText, from: remainder)
            }
        }

        var commaNote: String? = nil
        // A comma glued to a digit ("1,000 g", "1,5 kg") belongs to a number the
        // grammar did not read, not to a note — the whole line stays the name.
        if let comma = remainder.indices.first(where: { index in
            guard remainder[index] == "," else { return false }
            let next = remainder.index(after: index)
            return next == remainder.endIndex || !remainder[next].isNumber
        }) {
            let tail = collapseWhitespace(String(remainder[remainder.index(after: comma)...]))
            commaNote = tail.isEmpty ? nil : tail
            remainder = String(remainder[..<comma])
        }

        var name = collapseWhitespace(remainder)
        var sizeNote: String? = nil
        // "a large onion": an article only reads as a quantity before a unit (§7.2), so
        // it can still be sitting in front of the size word here. Look past it and drop
        // it with the size — left alone, "a large onion" fuzzy-matches Red onion, not Onion.
        let afterArticle = dropping(leadingWord: "a", from: name) ?? dropping(leadingWord: "an", from: name)
        if let size = leadingSizeWord(in: afterArticle ?? name) {
            sizeNote = size
            name = collapseWhitespace(String((afterArticle ?? name).dropFirst(size.count)))
        }
        var prepNote: String? = nil
        if let prep = trailingPrepPhrase(in: name) {
            prepNote = prep
            name = collapseWhitespace(String(name.dropLast(prep.count)))
        }
        if let withoutOf = dropping(leadingWord: "of", from: name) {
            name = withoutOf
        }

        noteParts.append(contentsOf: [rangeNote, sizeNote, prepNote, commaNote].compactMap { $0 })
        let note: String? = noteParts.isEmpty ? nil : noteParts.joined(separator: ", ")

        var line = StructuredLine(rawLine: rawLine,
                                  quantity: quantity,
                                  quantityText: quantityText,
                                  unitKey: unitKey,
                                  unitText: unitText,
                                  name: name,
                                  note: note,
                                  isUnresolved: false)
        if name.isEmpty {
            // §7.2: "If nothing is left, the line is unresolved with name = raw_line."
            line.isUnresolved = true
            line.name = stripped
        }
        return line
    }

    // MARK: - Pieces

    /// Removes every `( … )` group (outermost level; nested parens stay inside the
    /// note text) and returns their trimmed contents in order. An unbalanced "("
    /// runs to the end of the line, matching `IngredientNormalizer.removingParentheticals`.
    static func extractParentheticals(_ text: String) -> (text: String, notes: [String]) {
        var out = ""
        var notes: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "(" {
                if depth == 0 {
                    out.append(" ")
                } else {
                    current.append(character)
                }
                depth += 1
            } else if character == ")", depth > 0 {
                depth -= 1
                if depth == 0 {
                    let piece = collapseWhitespace(current)
                    if !piece.isEmpty { notes.append(piece) }
                    current = ""
                } else {
                    current.append(character)
                }
            } else if depth > 0 {
                current.append(character)
            } else {
                out.append(character)
            }
        }
        if depth > 0 {
            let piece = collapseWhitespace(current)
            if !piece.isEmpty { notes.append(piece) }
        }
        return (out, notes)
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Drops the matched unit spelling from the front of `text` (after the leading
    /// spaces `UnitTable.longestMatch` skipped), then one trailing "." and an "of".
    private static func droppingUnit(_ matchedText: String, from text: String) -> String {
        var rest = Substring(text).drop(while: { $0 == " " })
        rest = rest.dropFirst(matchedText.count)
        if rest.first == "." { rest = rest.dropFirst() }
        rest = rest.drop(while: { $0.isWhitespace })
        let result = String(rest)
        return dropping(leadingWord: "of", from: result) ?? result
    }

    /// `text` without a leading whole `word` (case-insensitive) and the whitespace
    /// after it, or nil when `text` does not start with that word.
    private static func dropping(leadingWord word: String, from text: String) -> String? {
        guard text.count >= word.count else { return nil }
        let head = text.prefix(word.count)
        guard head.lowercased() == word else { return nil }
        let after = text.dropFirst(word.count)
        if let next = after.first, !next.isWhitespace { return nil }
        return String(after.drop(while: { $0.isWhitespace }))
    }

    /// The size word at the start of a whitespace-collapsed name, as written.
    private static func leadingSizeWord(in name: String) -> String? {
        let lowered = name.lowercased()
        for size in sizeWords {
            if lowered == size || lowered.hasPrefix(size + " ") {
                return String(name.prefix(size.count))
            }
        }
        return nil
    }

    /// The prep phrase at the end of a whitespace-collapsed name, as written — or,
    /// when the name contains " plus more", everything from "plus more" onward.
    private static func trailingPrepPhrase(in name: String) -> String? {
        if let marker = name.range(of: " " + openEndedNoteMarker, options: [.caseInsensitive]) {
            return String(name[name.index(after: marker.lowerBound)...])
        }
        for phrase in prepWordsLongestFirst {
            if name.caseInsensitiveCompare(phrase) == .orderedSame { return name }
            if name.range(of: " " + phrase, options: [.caseInsensitive, .anchored, .backwards]) != nil {
                return String(name.suffix(phrase.count))
            }
        }
        return nil
    }
}
