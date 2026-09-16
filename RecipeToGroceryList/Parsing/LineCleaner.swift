import Foundation

/// One input line after cleaning (spec §5.2): either a candidate ingredient line or
/// a section header ("For the sauce:"). Headers are not ingredients — they appear
/// in Confirm as greyed dividers and survive in `recipes.raw_lines`, but never
/// become a `recipe_ingredients` row.
enum CleanedLine: Equatable, Sendable {
    case ingredient(String)
    case sectionHeader(String)

    /// The cleaned text either way — what goes into `RecipeDraft.rawLines`.
    var text: String {
        switch self {
        case .ingredient(let text), .sectionHeader(let text):
            return text
        }
    }

    var isSectionHeader: Bool {
        if case .sectionHeader = self { return true }
        return false
    }
}

/// Stage 0 of the pipeline (§5.2, shared by paste, URL and photo): split, trim,
/// drop empties, strip list decoration, classify headers. Pure and deterministic;
/// every path converges here so the splitter only ever sees one shape of line.
///
/// "Nothing silently dropped" (§1): the only lines this removes are *empty* ones.
/// A stripped bullet is decoration, not content.
enum LineCleaner {
    /// Pasted text: split on any newline, then `cleanLines`.
    static func clean(_ text: String) -> [CleanedLine] {
        cleanLines(text.components(separatedBy: .newlines))
    }

    /// Lines that already arrived as an array (JSON-LD `recipeIngredient`, OCR).
    static func cleanLines(_ lines: [String]) -> [CleanedLine] {
        lines.compactMap { line -> CleanedLine? in
            let stripped = stripBullet(line)
            guard !stripped.isEmpty else { return nil }
            return isSectionHeader(stripped) ? .sectionHeader(stripped) : .ingredient(stripped)
        }
    }

    /// Leading glyphs that are list decoration, never content. Dashes are included
    /// because "- 2 cups flour" is the most common paste shape; a range like "2–3"
    /// is never at the very start of a line, so no quantity is lost.
    static let bulletGlyphs: Set<Character> = [
        "-", "–", "—", "*", "•", "·", "▢", "☐", "✓", "✔", ">", "◦", "▪", "■", "□", "○", "●",
    ]

    /// Trims, then removes leading bullets and list numbering ("1.", "1)", "(1)",
    /// "①…⑳"). Numbering with a period is only stripped when whitespace (or the end)
    /// follows the period, so a decimal quantity like "1.5 cups" is left alone.
    /// A few passes cover "- 1. flour" style double decoration.
    static func stripBullet(_ line: String) -> String {
        var text = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        for _ in 0..<3 {
            while let first = text.first, bulletGlyphs.contains(first) {
                text = text.dropFirst().drop(while: { $0.isWhitespace })
            }
            guard let afterNumbering = droppingNumbering(text) else { break }
            text = afterNumbering.drop(while: { $0.isWhitespace })
        }
        return String(text)
    }

    /// §5.2: a line ending in ":" with no digit anywhere is a section header. Unicode
    /// fractions count as digits ("½ cup:" is not a header), so `isNumber` is used
    /// rather than an ASCII check.
    static func isSectionHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(":") else { return false }
        return !trimmed.contains(where: { $0.isNumber })
    }

    // MARK: - Pieces

    /// The text after one numbering token, or nil when the line is not numbered.
    /// Accepts "12." (period followed by whitespace or end), "12)", "(12)" and a
    /// single circled digit U+2460…U+2473.
    private static func droppingNumbering(_ text: Substring) -> Substring? {
        guard let first = text.first else { return nil }
        if first.unicodeScalars.count == 1,
           let scalar = first.unicodeScalars.first,
           (0x2460...0x2473).contains(scalar.value) {
            return text.dropFirst()
        }
        var rest = text
        var parenthesized = false
        if rest.first == "(" {
            parenthesized = true
            rest = rest.dropFirst()
        }
        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        rest = rest.dropFirst(digits.count)
        if parenthesized {
            guard rest.first == ")" else { return nil }
            return rest.dropFirst()
        }
        guard let delimiter = rest.first else { return nil }
        if delimiter == ")" { return rest.dropFirst() }
        if delimiter == "." {
            let afterPeriod = rest.dropFirst()
            if let next = afterPeriod.first, !next.isWhitespace { return nil }   // "1.5 cups" is a decimal
            return afterPeriod
        }
        return nil
    }
}
