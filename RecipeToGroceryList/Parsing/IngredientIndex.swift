import Foundation

/// One canonical ingredient as the resolver sees it: id, display name, category and
/// its owned aliases (already normalized with `IngredientNormalizer.normalize`, exactly
/// as `ingredient_aliases.alias` stores them — the alias table's PRIMARY KEY).
struct IngredientIndexEntry: Equatable, Identifiable, Sendable {
    let id: Int64
    let canonicalName: String
    let category: IngredientCategory
    let aliases: [String]

    init(id: Int64, canonicalName: String, category: IngredientCategory, aliases: [String] = []) {
        self.id = id
        self.canonicalName = canonicalName
        self.category = category
        self.aliases = aliases
    }
}

/// An in-memory snapshot of the ingredient registry for the deterministic layers of
/// resolution (spec §7.4, layers 0–1.5). The store builds one per parse
/// (`RecipeStore.ingredientIndex()`), so the pipeline never touches SQL and the
/// layers are pure functions that the golden corpus can score.
///
/// The lookups mirror the workout app's SQL resolution helpers at
/// `workout-logger@5bffddfb80fc` (`WorkoutStore+Exercises.swift`:
/// `exerciseID(canonicalNameMatching:)` = COLLATE NOCASE, `exerciseID(aliasMatching:)`
/// = the normalized alias PK, `exerciseID(looseMatching:)` = the loose key), with the
/// one food-specific tightening: a loose key that two *different* ingredients share
/// resolves to nothing, so no layer ever auto-merges two canonicals (§7.4).
struct IngredientIndex: Equatable, Sendable {
    let entries: [IngredientIndexEntry]

    private let positionByID: [Int64: Int]
    /// Layer 0: canonical name, lowercased and whitespace-collapsed (NOCASE).
    private let byExactName: [String: Int64]
    /// Layer 1: normalized alias → owner. One owner per alias, like the PK.
    private let byAlias: [String: Int64]
    /// Layer 1.5: loose key of every canonical and alias → owner; ambiguous keys removed.
    private let byLooseKey: [String: Int64]

    init(entries: [IngredientIndexEntry]) {
        self.entries = entries
        var positions: [Int64: Int] = [:]
        var exact: [String: Int64] = [:]
        var aliases: [String: Int64] = [:]
        var loose: [String: Int64] = [:]
        var ambiguous: Set<String> = []
        for (position, entry) in entries.enumerated() {
            if positions[entry.id] == nil { positions[entry.id] = position }
            let exactKey = Self.exactKey(entry.canonicalName)
            if !exactKey.isEmpty, exact[exactKey] == nil { exact[exactKey] = entry.id }
            for alias in entry.aliases where !alias.isEmpty {
                if aliases[alias] == nil { aliases[alias] = entry.id }
            }
            for text in [entry.canonicalName] + entry.aliases {
                let key = IngredientNormalizer.looseKey(text)
                guard !key.isEmpty else { continue }
                if let owner = loose[key] {
                    if owner != entry.id { ambiguous.insert(key) }
                } else {
                    loose[key] = entry.id
                }
            }
        }
        for key in ambiguous { loose.removeValue(forKey: key) }
        self.positionByID = positions
        self.byExactName = exact
        self.byAlias = aliases
        self.byLooseKey = loose
    }

    static let empty = IngredientIndex(entries: [])

    /// The lookup tables are derived from `entries`, so equality is equality of entries.
    static func == (lhs: IngredientIndex, rhs: IngredientIndex) -> Bool {
        lhs.entries == rhs.entries
    }

    var isEmpty: Bool { entries.isEmpty }

    func entry(id: Int64) -> IngredientIndexEntry? {
        guard let position = positionByID[id] else { return nil }
        return entries[position]
    }

    /// Layer 0: `canonical_name` match, case-insensitive, whitespace collapsed.
    func exactMatch(_ name: String) -> Int64? {
        let key = Self.exactKey(name)
        guard !key.isEmpty else { return nil }
        return byExactName[key]
    }

    /// Layer 1: the alias table, keyed by `IngredientNormalizer.normalize(name)`.
    func aliasMatch(_ name: String) -> Int64? {
        let key = IngredientNormalizer.normalize(name)
        guard !key.isEmpty else { return nil }
        return byAlias[key]
    }

    /// Layer 1.5: `looseKey(name)` against the loose keys of every canonical and
    /// alias. A key two different ingredients share is ambiguous and yields nil.
    func looseMatch(_ name: String) -> Int64? {
        let key = IngredientNormalizer.looseKey(name)
        guard !key.isEmpty else { return nil }
        return byLooseKey[key]
    }

    /// The owner of an already-normalized alias, for Confirm's "already means X" check.
    func aliasOwner(normalizedAlias: String) -> Int64? {
        byAlias[normalizedAlias]
    }

    /// Every canonical name, sorted case-insensitively — the list the on-device
    /// model's instructions anchor `canonicalGuess` to (§7.3).
    var canonicalNames: [String] {
        entries.map(\.canonicalName).sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The layer-0 key: whitespace-collapsed, lowercased.
    static func exactKey(_ name: String) -> String {
        name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
