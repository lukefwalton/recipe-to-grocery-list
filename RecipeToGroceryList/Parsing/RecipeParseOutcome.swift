import Foundation

// The FM-free seam between the pipeline and the on-device model (spec §7.3, §3
// "Deliberately different"). **Foundation only — no `FoundationModels` symbol appears
// here**, so everything the pipeline, Confirm and the tests touch compiles on every
// device and simulator; the gated `FoundationRecipeParser` produces these values and
// never sees more than the protocol. Shape ported from
// `WorkoutChatLog/Model/ParseOutcome.swift` at `workout-logger@5bffddfb80fc`, with the
// two departures the spec calls out: results are **per row** (a bad row becomes a
// visible row, never a reason to discard the others) and there is **no clarification
// case** — the Confirm screen is the clarification step.

/// Anything that can refine a recipe's ingredient lines: today the on-device model,
/// in tests a fake. It **proposes** only (§1: model proposes, app confirms, app
/// writes); the pipeline merges its rows back onto the regex result line by line.
/// `nil` means "declined / unavailable" — every line then falls back to the regex
/// splitter and the UI says "Parsed without on-device AI". Async because the real
/// implementation awaits the model; a fake returns immediately.
protocol RecipeRefining: Sendable {
    /// `lines` are the cleaned ingredient lines (headers already removed) in source
    /// order; `knownIngredients` are the canonical names the guess should anchor to.
    func refine(lines: [String], knownIngredients: [String]) async -> RecipeRefinement?
}

/// One model-described ingredient row, as plain `String`/`Double?` fields. Mirrors the
/// `@Generable` `ModelIngredientRow` field for field so the gated adapter is a dumb
/// copy and all the defensive logic lives in the always-compiled
/// `ModelIngredientMapping`. `confidence` stays a free-form string here on purpose:
/// mapping it to `RowConfidence` (unknown → `.low`) is the mapping layer's job.
struct RefinedRow: Equatable, Sendable {
    let rawLine: String
    let name: String
    let canonicalGuess: String
    let quantity: Double?
    let unit: String?
    let note: String?
    let confidence: String

    init(rawLine: String,
         name: String,
         canonicalGuess: String,
         quantity: Double? = nil,
         unit: String? = nil,
         note: String? = nil,
         confidence: String) {
        self.rawLine = rawLine
        self.name = name
        self.canonicalGuess = canonicalGuess
        self.quantity = quantity
        self.unit = unit
        self.note = note
        self.confidence = confidence
    }
}

/// The model's whole answer for one recipe: its rows plus an optional short warning
/// ("Two lines were not ingredients."). Purely advisory — nothing here is trusted
/// until `ModelIngredientMapping.merge` has checked it against the regex result.
struct RecipeRefinement: Equatable, Sendable {
    let rows: [RefinedRow]
    let warning: String?

    init(rows: [RefinedRow], warning: String? = nil) {
        self.rows = rows
        self.warning = warning
    }
}

/// What the pipeline hands the Confirm screen: the draft plus the two facts the UI
/// shows about how it was made. `usedOnDeviceAI` drives the "parsed with on-device
/// AI" note; `warning` is either the model's own caution or the family's
/// "Parsed without on-device AI." copy when the model declined.
struct ParsedRecipe: Equatable, Sendable {
    var draft: RecipeDraft
    var usedOnDeviceAI: Bool
    var warning: String?

    init(draft: RecipeDraft, usedOnDeviceAI: Bool, warning: String? = nil) {
        self.draft = draft
        self.usedOnDeviceAI = usedOnDeviceAI
        self.warning = warning
    }
}

/// Why the pipeline produced no draft at all. Both cases are about the *input* having
/// nothing to parse — the model can never cause a decline (§7.3: an unparseable model
/// response just means every line uses regex).
enum RecipeDeclineReason: String, Equatable, Sendable {
    /// Nothing but whitespace and list decoration.
    case noLines
    /// Only section headers ("For the sauce:") — no line to make a row from.
    case noIngredientLines

    /// User-facing copy for the Add screen's empty result.
    var message: String {
        switch self {
        case .noLines:
            return "Nothing to parse — no ingredient lines were found."
        case .noIngredientLines:
            return "Only section headers were found — no ingredient lines."
        }
    }
}

/// `draft | declined`, with a typed reason (§3: the clarification case is dropped).
enum RecipeParseOutcome: Equatable, Sendable {
    case draft(ParsedRecipe)
    case declined(RecipeDeclineReason)
}
