import Foundation

/// Which lines of a pasted page or a photo are ingredients, before any matcher runs.
///
/// The rest of the pipeline assumes it was handed an ingredient list. A screenshot
/// of a whole recipe is not one: "Let's get started", "Ingredients", and the method
/// all used to become rows, and the model was then asked to invent a grocery name
/// for each of them. This stage proposes the ingredient block. Headings stay
/// visible as dividers. Prose and steps stay in the draft, off the list, so they
/// can be put back. Link and paste use the proposal directly. The photo screen
/// shows it on the picture and lets the reader change it before parsing.
enum IngredientBlock {
    /// How `RecipePipeline` decides which admitted lines are ingredients.
    enum Selection: Equatable, Sendable {
        /// Every non-header line is an ingredient. Tests and any caller that already
        /// holds an ingredient list use this.
        case all
        /// Propose the block. Used for paste and for a link's extracted lines.
        case proposedBlock
        /// The photo review's choices. Indices are into the original line array,
        /// before empty lines are dropped. Headings are dividers either way.
        case indices(Set<Int>)
    }

    enum Role: Equatable, Sendable {
        /// Parse and resolve this line.
        case ingredient
        /// Grey divider. Never a shopping row.
        case sectionHeader
        /// Kept in the draft, struck off the list, until the reader puts it back.
        case excluded
    }

    struct Line: Equatable, Sendable {
        var text: String
        var role: Role
    }

    /// One role per input line, including blanks (those are `.excluded`).
    /// Indices match the input, which is what the photo checklist uses.
    static func propose(_ lines: [String]) -> [Role] {
        let stripped = lines.map { LineCleaner.stripBullet($0) }
        let kinds = stripped.map(classify)
        let range = span(in: kinds)
        return zip(stripped, kinds).enumerated().map { index, pair in
            role(for: pair.1, text: pair.0, inBlock: range.contains(index))
        }
    }

    /// A heading, intro, or method label. Checking it on the photo screen still
    /// does not turn it into a shopping row.
    static func isStructuralHeading(_ text: String) -> Bool {
        switch classify(LineCleaner.stripBullet(text)) {
        case .startHeading, .endHeading, .meta, .sectionHeader:
            return true
        case .empty, .instruction, .prose, .ingredient, .ambiguous:
            return false
        }
    }

    /// The lines the pipeline actually walks. Blanks are gone. Bullet decoration
    /// is already stripped, so the splitter sees one shape of line.
    static func admit(_ lines: [String], selection: Selection) -> [Line] {
        switch selection {
        case .all:
            return lines.compactMap { raw in
                let text = LineCleaner.stripBullet(raw)
                guard !text.isEmpty else { return nil }
                let role: Role = LineCleaner.isSectionHeader(text) ? .sectionHeader : .ingredient
                return Line(text: text, role: role)
            }
        case .proposedBlock:
            let kept = lines.compactMap { raw -> String? in
                let text = LineCleaner.stripBullet(raw)
                return text.isEmpty ? nil : text
            }
            return zip(kept, propose(kept)).map { Line(text: $0.0, role: $0.1) }
        case .indices(let chosen):
            // The review screen is still underneath Confirm, so an unchecked line
            // is left there instead of being copied onto Confirm as a struck row.
            return lines.enumerated().compactMap { index, raw in
                let text = LineCleaner.stripBullet(raw)
                guard !text.isEmpty else { return nil }
                if isStructuralHeading(text) {
                    return Line(text: text, role: .sectionHeader)
                }
                guard chosen.contains(index) else { return nil }
                return Line(text: text, role: .ingredient)
            }
        }
    }

    // MARK: - Classification

    private enum Kind: Equatable {
        case empty
        case startHeading
        case endHeading
        case meta
        case sectionHeader
        case instruction
        case prose
        case ingredient
        case ambiguous
    }

    private static func role(for kind: Kind, text: String, inBlock: Bool) -> Role {
        if text.isEmpty { return .excluded }
        switch kind {
        case .startHeading, .endHeading, .meta, .sectionHeader:
            return .sectionHeader
        case .instruction, .prose, .empty:
            return .excluded
        case .ingredient, .ambiguous:
            return inBlock ? .ingredient : .excluded
        }
    }

    private static func classify(_ text: String) -> Kind {
        if text.isEmpty { return .empty }
        let key = headingKey(text)
        if let named = lexicon(key) { return named }
        if key.hasPrefix("for the "), key.split(separator: " ").count <= 6 {
            return .sectionHeader
        }
        if LineCleaner.isSectionHeader(text) { return .sectionHeader }
        if hasLeadingQuantity(text) { return .ingredient }
        if isInstruction(text) { return .instruction }
        if isProse(text) || greetings.contains(key) { return .prose }
        return .ambiguous
    }

    /// Lowercased, apostrophes folded, parentheticals removed, trailing
    /// punctuation dropped. "Ingredients (8):" and "Let’s get started!" share a
    /// key with the plain heading.
    static func headingKey(_ text: String) -> String {
        var value = text.lowercased()
        value = value.replacingOccurrences(of: "’", with: "'")
        value = value.replacingOccurrences(of: "‘", with: "'")
        value = value.replacingOccurrences(of: "`", with: "'")
        while let open = value.firstIndex(of: "("),
              let close = value[open...].firstIndex(of: ")"),
              close >= open {
            value.removeSubrange(open...close)
        }
        value = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        while let last = value.last, ":.!?".contains(last) {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static let greetings: Set<String> = [
        "welcome", "hello", "hi", "hey", "introduction", "overview",
    ]

    private static func lexicon(_ key: String) -> Kind? {
        if key.isEmpty { return nil }
        if isStart(key) { return .startHeading }
        if isEnd(key) { return .endHeading }
        if isMeta(key) { return .meta }
        return nil
    }

    private static func isStart(_ key: String) -> Bool {
        if startExact.contains(key) { return true }
        return key.hasPrefix("ingredients ") || key.hasPrefix("ingredient ")
    }

    private static func isEnd(_ key: String) -> Bool {
        if endExact.contains(key) { return true }
        return endPrefixes.contains { key.hasPrefix($0) }
    }

    private static func isMeta(_ key: String) -> Bool {
        if metaExact.contains(key) { return true }
        return metaPrefixes.contains { key.hasPrefix($0) }
    }

    private static let startExact: Set<String> = [
        "ingredient", "ingredients", "ingredient list", "ingredients list",
        "what you'll need", "what you will need", "what you need",
        "you'll need", "you will need", "you need",
    ]

    private static let endExact: Set<String> = [
        "instruction", "instructions", "direction", "directions",
        "method", "methods", "steps", "step", "preparation",
        "notes", "note", "nutrition", "nutrition facts", "nutrition information",
        "equipment", "equipment list", "tools", "tool",
        "let's get started", "lets get started", "let's cook", "lets cook",
        "let's make", "lets make", "let's begin", "lets begin",
        "how to make", "how to cook", "how to", "how to prepare",
        "you may also like", "related", "related recipes", "comments",
        "rate this recipe", "did you make this", "did you make this recipe",
        "get started", "let's", "lets",
        "print recipe", "pin recipe", "save recipe",
    ]

    private static let endPrefixes: [String] = [
        "instructions ", "instruction ", "directions ", "direction ",
        "steps ", "step ", "notes ", "note ",
        "let's ", "lets ", "how to ", "nutrition ",
    ]

    private static let metaExact: Set<String> = [
        "prep time", "cook time", "total time", "active time",
        "servings", "serving", "yield", "serves", "course", "cuisine",
        "author", "keywords", "keyword", "diet", "difficulty",
        "print", "jump to recipe", "jump to the recipe",
    ]

    private static let metaPrefixes: [String] = [
        "prep time", "cook time", "total time", "active time",
        "servings", "serves ", "yield ", "course ", "cuisine ", "difficulty ",
    ]

    private static func hasLeadingQuantity(_ text: String) -> Bool {
        IngredientLineSplitter.split(text).quantity != nil
    }

    /// Imperatives that start a method line. "Roast chicken" is an ingredient,
    /// so those verbs only count when the line is clearly a step.
    private static let methodVerbs: Set<String> = [
        "preheat", "simmer", "whisk", "knead", "refrigerate", "marinate",
        "saute", "sauté", "garnish", "drizzle", "sprinkle", "stir", "mix",
        "combine", "add", "pour", "serve", "enjoy", "place", "transfer",
        "bring", "reduce", "cover", "uncover", "season", "prepare", "fold",
        "spread", "grease", "cool", "chill", "drain", "rinse", "remove",
        "set", "let", "wait", "rest", "beat", "sift", "toss", "plate",
        "repeat", "continue", "adjust", "brush", "scrape", "return",
        "discard", "reserve", "divide", "boil",
    ]

    private static let ingredientShapedVerbs: Set<String> = [
        "roast", "grill", "fry", "heat", "cook", "bake", "toast", "steam", "poach", "blanch", "line",
    ]

    private static let glueWords: Set<String> = [
        "the", "a", "an", "your", "it", "them", "until", "for", "and", "to",
        "in", "over", "with", "about", "well", "together", "gently", "thoroughly",
    ]

    private static func isInstruction(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { word -> String in
            word.trimmingCharacters(in: .punctuationCharacters).lowercased()
        }.filter { !$0.isEmpty }
        guard let first = words.first, words.count >= 2 else { return false }
        if methodVerbs.contains(first) { return true }
        guard ingredientShapedVerbs.contains(first) else { return false }
        if words.count >= 6 { return true }
        return glueWords.contains(words[1])
    }

    private static func isProse(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        if words.count >= 10 { return true }
        if words.count >= 7 && text.contains(where: { ".!?".contains($0) }) { return true }
        return false
    }

    /// The ingredient region. A heading named Ingredients wins. Otherwise the
    /// region starts at the first real quantity line, and a list of bare names
    /// ("garlic", "onion", "salt") is kept whole. It stops at Instructions,
    /// "Let's get started", or the first method line after the food.
    private static func span(in kinds: [Kind]) -> Range<Int> {
        guard !kinds.isEmpty else { return 0..<0 }
        let startIndex: Int
        if let heading = kinds.firstIndex(of: .startHeading) {
            startIndex = kinds.index(after: heading)
        } else if let firstIngredient = kinds.firstIndex(of: .ingredient) {
            startIndex = firstIngredient
        } else if let firstName = kinds.firstIndex(of: .ambiguous) {
            startIndex = firstName
        } else {
            return 0..<0
        }

        var start = startIndex
        while start > 0 && kinds[start - 1] == .sectionHeader {
            start -= 1
        }

        var end = kinds.count
        if startIndex < kinds.count,
           let boundary = kinds[startIndex...].firstIndex(of: .endHeading) {
            end = boundary
        }
        while end > start {
            switch kinds[end - 1] {
            case .ingredient, .ambiguous, .sectionHeader:
                return start..<end
            default:
                end -= 1
            }
        }
        return start..<end
    }
}
