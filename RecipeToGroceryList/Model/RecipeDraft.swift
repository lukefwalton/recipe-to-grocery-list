import Foundation

// The keystone contract of the app (spec §1 "One write path"): every input path —
// pasted text, a fetched page, a photographed page — produces a `RecipeDraft`, the
// Confirm screen edits it, and `RecipeStore.save` is the only thing that turns it
// into rows. Nothing here can persist anything; the model, the fuzzy layers, and
// the user all *propose* through these values, and the store writes.

/// Where a recipe's raw lines came from. Raw values match the schema's
/// `CHECK (source_kind IN ('url','text','photo'))`.
enum SourceKind: String, Codable, CaseIterable, Sendable {
    case url, text, photo

    var displayName: String {
        switch self {
        case .url: return "Link"
        case .text: return "Pasted"
        case .photo: return "Photo"
        }
    }

    var symbol: String {
        switch self {
        case .url: return "link"
        case .text: return "doc.on.clipboard"
        case .photo: return "camera"
        }
    }
}

/// What an input path knows about the recipe besides its lines (§5).
struct RecipeSource: Equatable, Sendable {
    var kind: SourceKind
    /// Final URL after redirects for `.url`; nil otherwise. Stored as `source_ref`.
    var ref: String?
    /// A best-effort title (page `name`, first pasted line, …). The user can edit it.
    var titleGuess: String?
    /// Raw `recipeYield` / servings text, display only — never parsed (§2 non-goal).
    var servingsText: String?

    init(kind: SourceKind, ref: String? = nil, titleGuess: String? = nil, servingsText: String? = nil) {
        self.kind = kind
        self.ref = ref
        self.titleGuess = titleGuess
        self.servingsText = servingsText
    }
}

/// How a row got its ingredient (§7.4). Persisted verbatim in
/// `recipe_ingredients.resolution`; the only "telemetry" the app has, and it never
/// leaves the database. Raw values match the schema CHECK.
enum RowResolution: String, Codable, CaseIterable, Sendable {
    case exact, alias, loose, fuzzy, embedding, llm, user, none
}

/// The model's self-reported confidence for a row (§7.3). Deterministic layers
/// report `.high`; an unknown model string maps to `.low` (never up).
enum RowConfidence: String, Codable, CaseIterable, Sendable {
    case high, medium, low

    /// Tolerant decode of the model's free-form string: anything unrecognised is
    /// `.low`, so a misspelling can only make a row *more* visible, never less.
    init(modelString raw: String) {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high": self = .high
        case "medium", "med": self = .medium
        default: self = .low
        }
    }
}

/// The ingredient a draft row points at: an existing canonical (database id) or
/// one the user asked to create in this Confirm session, which only gets an id when
/// `RecipeStore.save` runs the transaction.
enum IngredientRef: Hashable, Sendable {
    case existing(Int64)
    case pending(UUID)
}

/// A proposed canonical for a row (layers ≥ 2 and the LLM's guess). It proposes;
/// the user confirms. `via` is the layer that produced it (`.fuzzy`, `.embedding`
/// or `.llm`).
struct IngredientSuggestion: Equatable, Identifiable, Sendable {
    let ingredientID: Int64
    let canonicalName: String
    let score: Double
    let via: RowResolution

    var id: Int64 { ingredientID }
}

/// The Confirm screen's row state (§7.5), derived from the row's fields.
enum ConfirmRowState: Equatable, Sendable {
    /// exact / alias / loose / user-chosen, high confidence — accepted by Save.
    case resolved
    /// fuzzy / embedding hit, or medium confidence — accepted by Save, shown with a
    /// `warning`-tone dot and "matched to X".
    case highlighted
    /// The LLM's `canonicalGuess` hit an existing canonical — "Looks like X", needs
    /// a **Use** tap (the model never writes an alias).
    case suggested
    /// Nothing hit (or low confidence) — needs Create / Same as… / Keep as text.
    case new
    /// The user chose *Keep as text*: stored with a NULL ingredient under Other.
    case text
    /// The user removed the line (not an ingredient). Kept in `raw_lines`, not in
    /// `recipe_ingredients`.
    case removed
}

/// One raw line as the Confirm screen sees it. `rawLine` is never edited; every
/// other field is the app's (or the model's, or the user's) proposal about it.
struct DraftRow: Identifiable, Equatable, Sendable {
    var id: UUID
    /// Index into `RecipeDraft.rawLines`, so the Confirm screen can interleave
    /// section-header dividers in source order.
    let lineIndex: Int
    /// The input line, unchanged (after bullet stripping). Stored verbatim.
    let rawLine: String
    /// Cleaned name as written ("veggie broth"), the input to resolution.
    var name: String
    var quantity: Double?
    /// Normalized unit (§8) or nil.
    var unitKey: String?
    /// The unit as written, for display.
    var unitText: String?
    var note: String?
    /// The canonical this row maps to; nil while unresolved or when kept as text.
    var ingredient: IngredientRef?
    /// Display name of `ingredient` at the time it was set (canonical name, or the
    /// pending ingredient's name). Denormalized so rows render without a lookup.
    var ingredientName: String?
    var resolution: RowResolution
    var confidence: RowConfidence
    /// Layer-4 proposal (requires **Use**). Only meaningful while `ingredient == nil`.
    var suggestion: IngredientSuggestion?
    /// Near misses the user can pick from when changing the ingredient.
    var alternatives: [IngredientSuggestion]
    var keepAsText: Bool
    var isRemoved: Bool

    init(id: UUID = UUID(),
         lineIndex: Int,
         rawLine: String,
         name: String,
         quantity: Double? = nil,
         unitKey: String? = nil,
         unitText: String? = nil,
         note: String? = nil,
         ingredient: IngredientRef? = nil,
         ingredientName: String? = nil,
         resolution: RowResolution = .none,
         confidence: RowConfidence = .high,
         suggestion: IngredientSuggestion? = nil,
         alternatives: [IngredientSuggestion] = [],
         keepAsText: Bool = false,
         isRemoved: Bool = false) {
        self.id = id
        self.lineIndex = lineIndex
        self.rawLine = rawLine
        self.name = name
        self.quantity = quantity
        self.unitKey = unitKey
        self.unitText = unitText
        self.note = note
        self.ingredient = ingredient
        self.ingredientName = ingredientName
        self.resolution = resolution
        self.confidence = confidence
        self.suggestion = suggestion
        self.alternatives = alternatives
        self.keepAsText = keepAsText
        self.isRemoved = isRemoved
    }

    /// The §7.5 state table, as one derivation so the UI, the Save gate and the
    /// tests can never disagree about what a row "is".
    var state: ConfirmRowState {
        if isRemoved { return .removed }
        if keepAsText { return .text }
        if ingredient != nil {
            if resolution == .fuzzy || resolution == .embedding || confidence == .medium {
                return .highlighted
            }
            return .resolved
        }
        if suggestion != nil { return .suggested }
        return .new
    }

    /// Save is disabled while any row still needs a tap (§7.5). A suggested row
    /// blocks too: accepting it silently would let the model write an alias.
    var blocksSave: Bool {
        state == .new || state == .suggested
    }
}

/// An ingredient the user asked to create from Confirm (`is_custom = 1`). Gets its
/// database id inside `RecipeStore.save`.
struct PendingIngredient: Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var category: IngredientCategory

    init(id: UUID = UUID(), name: String, category: IngredientCategory = .other) {
        self.id = id
        self.name = name
        self.category = category
    }
}

/// An alias the user asked to write via *Same as…* or *Use* (§7.5). `alias` is the
/// row's name as written; the store normalizes it (§7.1) at write time, refusing
/// the whole save if the normalized alias already belongs to another canonical.
struct PendingAlias: Equatable, Sendable {
    var alias: String
    var target: IngredientRef

    init(alias: String, target: IngredientRef) {
        self.alias = alias
        self.target = target
    }
}

/// A whole proposed recipe. Every input path produces one of these, the Confirm
/// screen edits it, and it flows through the single
/// `validate → transaction → save` path (`RecipeStore.save`).
struct RecipeDraft: Equatable, Sendable {
    var title: String
    var source: RecipeSource
    /// Every non-empty line we were given, in order, bullets stripped — including
    /// section headers and lines the user later removed. Persisted as `raw_lines`
    /// so a future pipeline can re-parse without re-fetching.
    var rawLines: [String]
    /// One row per ingredient line (never per header), in source order.
    var rows: [DraftRow]
    var newIngredients: [PendingIngredient]
    var newAliases: [PendingAlias]

    init(title: String,
         source: RecipeSource,
         rawLines: [String],
         rows: [DraftRow],
         newIngredients: [PendingIngredient] = [],
         newAliases: [PendingAlias] = []) {
        self.title = title
        self.source = source
        self.rawLines = rawLines
        self.rows = rows
        self.newIngredients = newIngredients
        self.newAliases = newAliases
    }

    /// Rows that will be written to `recipe_ingredients` (everything not removed).
    var keptRows: [DraftRow] { rows.filter { !$0.isRemoved } }

    /// Indices into `rawLines` that are not ingredient rows — section headers the
    /// Confirm screen renders as greyed dividers (§5.2).
    var headerLineIndices: [Int] {
        let rowIndices = Set(rows.map(\.lineIndex))
        return rawLines.indices.filter { !rowIndices.contains($0) }
    }

    /// The Save gate (§7.5): a title, at least one kept row, and no row still
    /// waiting on a tap. `RecipeValidator` re-checks all of this at write time.
    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !keptRows.isEmpty
            && !rows.contains(where: \.blocksSave)
    }

    func row(id: UUID) -> DraftRow? {
        rows.first { $0.id == id }
    }

    func pendingIngredient(id: UUID) -> PendingIngredient? {
        newIngredients.first { $0.id == id }
    }
}
