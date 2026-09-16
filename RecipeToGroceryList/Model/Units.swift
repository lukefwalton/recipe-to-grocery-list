import Foundation

/// One entry of the unit table (spec §8): a normalized `key` and the spellings the
/// splitter accepts for it. `spellings` are matched case-insensitively; the one
/// place normalization does *not* lowercase first is the single-letter
/// `T` (tablespoon) vs `t` (teaspoon), which live in `caseSensitiveSpellings`.
struct UnitDefinition: Equatable, Sendable {
    let key: String
    let singular: String
    let plural: String
    let spellings: [String]
    let caseSensitiveSpellings: [String]

    init(key: String, singular: String, plural: String, spellings: [String], caseSensitiveSpellings: [String] = []) {
        self.key = key
        self.singular = singular
        self.plural = plural
        self.spellings = spellings
        self.caseSensitiveSpellings = caseSensitiveSpellings
    }

    func displayName(for quantity: Double?) -> String {
        guard let quantity else { return singular }
        return abs(quantity - 1) < 0.0001 ? singular : plural
    }
}

/// The closed unit vocabulary. Quantities are only ever summed when `unit_key`
/// matches after normalization (§8); nothing here converts between keys.
///
/// The spec's starting set plus a handful the golden corpus needed (fluid ounces,
/// quarts/pints/gallons, jars, bags, stalks, dashes, handfuls). Extend here and in
/// the corpus together.
enum UnitTable {
    static let all: [UnitDefinition] = [
        UnitDefinition(key: "tsp", singular: "tsp", plural: "tsp",
                       spellings: ["tsp", "tsps", "teaspoon", "teaspoons"], caseSensitiveSpellings: ["t"]),
        UnitDefinition(key: "tbsp", singular: "tbsp", plural: "tbsp",
                       spellings: ["tbsp", "tbsps", "tablespoon", "tablespoons", "tbs", "tbl"], caseSensitiveSpellings: ["T"]),
        UnitDefinition(key: "cup", singular: "cup", plural: "cups",
                       spellings: ["cup", "cups", "c"]),
        UnitDefinition(key: "floz", singular: "fl oz", plural: "fl oz",
                       spellings: ["fl oz", "fl. oz", "fl.oz", "floz", "fluid ounce", "fluid ounces"]),
        UnitDefinition(key: "oz", singular: "oz", plural: "oz",
                       spellings: ["oz", "ounce", "ounces"]),
        UnitDefinition(key: "lb", singular: "lb", plural: "lb",
                       spellings: ["lb", "lbs", "pound", "pounds"]),
        UnitDefinition(key: "g", singular: "g", plural: "g",
                       spellings: ["g", "gram", "grams"]),
        UnitDefinition(key: "kg", singular: "kg", plural: "kg",
                       spellings: ["kg", "kilogram", "kilograms"]),
        UnitDefinition(key: "ml", singular: "ml", plural: "ml",
                       spellings: ["ml", "milliliter", "milliliters", "millilitre", "millilitres"]),
        UnitDefinition(key: "l", singular: "l", plural: "l",
                       spellings: ["l", "liter", "liters", "litre", "litres"]),
        UnitDefinition(key: "quart", singular: "quart", plural: "quarts",
                       spellings: ["quart", "quarts", "qt", "qts"]),
        UnitDefinition(key: "pint", singular: "pint", plural: "pints",
                       spellings: ["pint", "pints", "pt", "pts"]),
        UnitDefinition(key: "gallon", singular: "gallon", plural: "gallons",
                       spellings: ["gallon", "gallons", "gal"]),
        UnitDefinition(key: "clove", singular: "clove", plural: "cloves",
                       spellings: ["clove", "cloves"]),
        UnitDefinition(key: "can", singular: "can", plural: "cans",
                       spellings: ["can", "cans", "tin", "tins"]),
        UnitDefinition(key: "jar", singular: "jar", plural: "jars",
                       spellings: ["jar", "jars"]),
        UnitDefinition(key: "bottle", singular: "bottle", plural: "bottles",
                       spellings: ["bottle", "bottles"]),
        UnitDefinition(key: "bag", singular: "bag", plural: "bags",
                       spellings: ["bag", "bags"]),
        UnitDefinition(key: "box", singular: "box", plural: "boxes",
                       spellings: ["box", "boxes"]),
        UnitDefinition(key: "bunch", singular: "bunch", plural: "bunches",
                       spellings: ["bunch", "bunches"]),
        UnitDefinition(key: "pinch", singular: "pinch", plural: "pinches",
                       spellings: ["pinch", "pinches"]),
        UnitDefinition(key: "dash", singular: "dash", plural: "dashes",
                       spellings: ["dash", "dashes"]),
        UnitDefinition(key: "handful", singular: "handful", plural: "handfuls",
                       spellings: ["handful", "handfuls"]),
        UnitDefinition(key: "piece", singular: "piece", plural: "pieces",
                       spellings: ["piece", "pieces", "whole"]),
        UnitDefinition(key: "slice", singular: "slice", plural: "slices",
                       spellings: ["slice", "slices"]),
        UnitDefinition(key: "stick", singular: "stick", plural: "sticks",
                       spellings: ["stick", "sticks"]),
        UnitDefinition(key: "stalk", singular: "stalk", plural: "stalks",
                       spellings: ["stalk", "stalks", "rib", "ribs"]),
        UnitDefinition(key: "head", singular: "head", plural: "heads",
                       spellings: ["head", "heads"]),
        UnitDefinition(key: "sprig", singular: "sprig", plural: "sprigs",
                       spellings: ["sprig", "sprigs"]),
        UnitDefinition(key: "package", singular: "package", plural: "packages",
                       spellings: ["package", "packages", "pkg", "pkgs", "packet", "packets"]),
    ]

    static let keys: [String] = all.map(\.key)

    private static let byKey: [String: UnitDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

    /// Case-insensitive spelling → key.
    private static let byLowercasedSpelling: [String: String] = {
        var map: [String: String] = [:]
        for unit in all {
            for spelling in unit.spellings { map[spelling.lowercased()] = unit.key }
        }
        return map
    }()

    /// The two case-sensitive spellings (`T`, `t`) → key.
    private static let byCaseSensitiveSpelling: [String: String] = {
        var map: [String: String] = [:]
        for unit in all {
            for spelling in unit.caseSensitiveSpellings { map[spelling] = unit.key }
        }
        return map
    }()

    /// Every accepted spelling, longest first, so a prefix match prefers "fl oz"
    /// over "fl" and "tablespoons" over "tablespoon".
    static let spellingsLongestFirst: [String] = {
        let everything = all.flatMap { $0.spellings + $0.caseSensitiveSpellings }
        return Array(Set(everything)).sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            return a < b
        }
    }()

    static func definition(forKey key: String) -> UnitDefinition? { byKey[key] }

    static func isKnownKey(_ key: String) -> Bool { byKey[key] != nil }

    /// The key for one spelling as written ("Tbsp.", "cups", "T", "t"), or nil. A
    /// trailing period is tolerated ("tsp." / "oz.").
    static func key(forSpelling spelling: String) -> String? {
        var text = spelling.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if let exact = byCaseSensitiveSpelling[text] { return exact }
        return byLowercasedSpelling[text.lowercased()]
    }

    /// Whether `spelling` is exactly one of the accepted spellings (used by the
    /// splitter to decide if the token after a quantity is a unit).
    static func isSpelling(_ spelling: String) -> Bool {
        key(forSpelling: spelling) != nil
    }

    /// Longest accepted spelling at the start of `text` (after any leading spaces),
    /// requiring a word boundary after it: end of text, whitespace, `.`, `,` or `)`.
    /// Returns the key and the exact matched text (so `unit_text` can keep the
    /// author's spelling). `T`/`t` match case-sensitively; everything else ignores case.
    static func longestMatch(atStartOf text: Substring) -> (key: String, matchedText: String)? {
        let trimmed = text.drop(while: { $0 == " " })
        guard !trimmed.isEmpty else { return nil }
        for spelling in spellingsLongestFirst {
            guard trimmed.count >= spelling.count else { continue }
            let head = trimmed.prefix(spelling.count)
            let matches: Bool
            if byCaseSensitiveSpelling[spelling] != nil, spelling.count == 1 {
                matches = head == Substring(spelling)
            } else {
                matches = head.lowercased() == spelling.lowercased()
            }
            guard matches else { continue }
            let rest = trimmed.dropFirst(spelling.count)
            if let next = rest.first, !(next.isWhitespace || next == "." || next == "," || next == ")") {
                continue
            }
            guard let key = key(forSpelling: String(head)) else { continue }
            return (key, String(head))
        }
        return nil
    }

    /// "cup" / "cups" for a key and quantity, or the key itself if unknown.
    static func displayName(forKey key: String, quantity: Double?) -> String {
        byKey[key]?.displayName(for: quantity) ?? key
    }
}

/// Number formatting for quantities (§8): common eighths and thirds render as
/// fractions, integers stay bare, anything else gets one decimal. Never converts.
enum QuantityFormat {
    /// Fraction glyphs for the values the spec calls "common eighths/thirds".
    static let fractions: [(value: Double, glyph: String)] = [
        (1.0 / 8.0, "⅛"), (1.0 / 4.0, "¼"), (1.0 / 3.0, "⅓"), (3.0 / 8.0, "⅜"),
        (1.0 / 2.0, "½"), (5.0 / 8.0, "⅝"), (2.0 / 3.0, "⅔"), (3.0 / 4.0, "¾"), (7.0 / 8.0, "⅞"),
    ]

    static let fractionTolerance = 0.01

    static func string(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let whole = value.rounded(.down)
        let fraction = value - whole
        if fraction < fractionTolerance || fraction > 1 - fractionTolerance {
            return String(Int(value.rounded()))
        }
        if let glyph = fractions.first(where: { abs($0.value - fraction) < fractionTolerance })?.glyph {
            return whole > 0 ? "\(Int(whole))\(glyph)" : glyph
        }
        let oneDecimal = (value * 10).rounded() / 10
        if oneDecimal == oneDecimal.rounded() {
            return String(Int(oneDecimal))
        }
        return String(format: "%.1f", oneDecimal)
    }

    /// "2 cups", "½ tsp", "3" (no unit), "1 can".
    static func string(quantity: Double?, unitKey: String?, unitText: String? = nil) -> String {
        let amount = quantity.map(string)
        let unit: String?
        if let unitKey {
            unit = UnitTable.displayName(forKey: unitKey, quantity: quantity)
        } else {
            unit = unitText
        }
        switch (amount, unit) {
        case let (amount?, unit?): return "\(amount) \(unit)"
        case let (amount?, nil): return amount
        case let (nil, unit?): return unit
        case (nil, nil): return ""
        }
    }
}
