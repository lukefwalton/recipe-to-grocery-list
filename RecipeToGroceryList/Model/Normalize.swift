import Foundation

/// The one normalization for ingredient names and aliases (spec §7.1). It is the
/// alias table's PRIMARY KEY key *and* the input to every matching layer, so the two
/// can never disagree: an alias is stored as `normalize(alias)` and looked up as
/// `normalize(name)`.
///
/// Deterministic and dependency-free. `scripts/ingredient_normalize.py` mirrors it
/// step for step so the seed build can check alias uniqueness with the same rules;
/// `SeedIngredientsTests` re-checks the invariants at runtime with *this* code, so
/// drift between the two shows up as a failing test, not a silently dropped alias.
enum IngredientNormalizer {

    /// §7.1 in order: lowercase, Unicode NFKC, strip diacritics, drop parentheticals,
    /// collapse whitespace, trim, strip leading/trailing punctuation, remove a leading
    /// article, singularize the last word.
    static func normalize(_ raw: String) -> String {
        // NFKC first so "½"/"ﬁ"-style compatibility forms fold before anything else.
        var text = raw.precomposedStringWithCompatibilityMapping
        // Strip diacritics (jalapeño → jalapeno, crème → creme) and lowercase.
        text = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        text = removingParentheticals(text)
        // Collapse every run of whitespace/newlines to one space.
        var tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        tokens = tokens.compactMap { token in
            let stripped = trimmingPunctuation(token)
            return stripped.isEmpty ? nil : stripped
        }
        // A leading article only when something follows it ("a" alone stays "a").
        if tokens.count > 1, articles.contains(tokens[0]) {
            tokens.removeFirst()
        }
        if let last = tokens.last {
            tokens[tokens.count - 1] = singularize(last)
        }
        return tokens.joined(separator: " ")
    }

    /// Layer 1.5's key (§7.4): the normalized form with every non-alphanumeric removed,
    /// so "chick peas", "chickpeas" and "chick-peas" all join. Applied to both sides
    /// of a comparison, so equality stays meaningful.
    static func looseKey(_ raw: String) -> String {
        String(normalize(raw).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// A stable slug for a user-created canonical: normalized, then every run of
    /// non-alphanumerics becomes one underscore ("Crème Fraîche" → "creme_fraiche").
    /// Mirrors how the seed authors its slugs, so a custom that later ships as a seed
    /// entry lines up on the same key.
    static func slugify(_ name: String) -> String {
        let lowered = name.precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
        return lowered.split { !($0.isLetter || $0.isNumber) }.joined(separator: "_")
    }

    // MARK: - Pieces

    static let articles: Set<String> = ["a", "an", "the"]

    /// Mass nouns and proper names that end in "s" but are not plurals. Stripping
    /// their "s" would not break matching (both sides normalize the same way) but
    /// it would make aliases in the seed source read wrong, so leave them alone.
    static let singularExceptions: Set<String> = [
        "hummus", "couscous", "molasses", "asparagus", "swiss", "brussels",
        "grits", "oats", "greens", "chips", "flakes", "sprinkles",
    ]

    /// One trailing plural, on words longer than 3 characters (spec: "tomatoes →
    /// tomato, but hummus stays"). Words ending in -us / -ss / -is are never
    /// plurals in this vocabulary and keep their s.
    ///
    /// Letters **and hyphens** qualify, because a hyphenated compound is still one
    /// food word and `looseKey` promises that "chick peas", "chickpeas" and
    /// "chick-peas" all join — they cannot if the hyphenated spelling keeps its
    /// plural. Anything else with a non-letter ("m&ms", "2%") is left alone: those
    /// are not plurals to strip. Verified against the whole seed: allowing the
    /// hyphen changes no canonical, alias or loose key in `seed_source.json`.
    static func singularize(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy({ $0.isLetter || $0 == "-" }) else { return word }
        if singularExceptions.contains(word) { return word }
        if word.hasSuffix("ies"), word.count > 4 {
            return String(word.dropLast(3)) + "y"                 // berries → berry
        }
        for suffix in ["oes", "ches", "shes", "sses", "xes", "zes"] where word.hasSuffix(suffix) {
            return String(word.dropLast(2))                       // tomatoes → tomato, peaches → peach
        }
        if word.hasSuffix("us") || word.hasSuffix("ss") || word.hasSuffix("is") {
            return word                                           // hummus, molasses, … stay
        }
        if word.hasSuffix("s") {
            return String(word.dropLast())                        // onions → onion
        }
        return word
    }

    /// Removes every `( … )` group, including nested ones, and any unbalanced
    /// opener to the end of the string.
    static func removingParentheticals(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                result.append(character)
            }
        }
        return result
    }

    /// Strips leading and trailing punctuation/symbols from one token while keeping
    /// interior ones ("half-and-half" survives, "onion," and "*salt*" are cleaned).
    static func trimmingPunctuation(_ token: String) -> String {
        let scalars = token.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isPunctuation(scalars[start]) { start = scalars.index(after: start) }
        while end > start, isPunctuation(scalars[scalars.index(before: end)]) { end = scalars.index(before: end) }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars[start..<end])
        return String(kept)
    }

    private static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
    }
}
