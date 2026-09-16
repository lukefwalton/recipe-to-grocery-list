import Foundation

/// Pure, **FoundationModels-free** merge of the model's rows back onto the regex
/// splitter's result (spec §7.3 "Mapping back"). It lives in always-compiled code on
/// purpose: the gated `FoundationRecipeParser` copies plain `String`/`Double?` fields
/// off its `@Generable` response into `RefinedRow`s and hands them here, so the
/// *defensive* logic — the part most likely to have a bug — is unit-tested without
/// importing FoundationModels. Ported from
/// `WorkoutChatLog/Parsing/ModelDraftMapping.swift` at `workout-logger@5bffddfb80fc`.
///
/// The one deliberate departure from that file (§3 "Deliberately different"): the
/// workout mapping is **all-or-nothing** — one unreadable set declines the whole entry.
/// Here every decision is **per row**. A recipe has 5–30 lines and one weird line must
/// never cost the user the other fourteen, so an unmatched, skipped or unreadable row
/// simply keeps its regex result and the rest still benefit from the model.
///
/// The governing rules, each locked by a test:
/// - Rows are matched to input lines by `rawLine` (trimmed). The merge iterates the
///   *regex* lines, so the model can never add or remove a line; an input line the
///   model skipped keeps its regex result, a model row that matches nothing is ignored.
/// - The model may not invent numbers: its `quantity` is used only where the regex
///   also found one, and only when finite and ≥ 0. Otherwise the regex value stands.
/// - Its `unit` is used only when `UnitTable.key(forSpelling:)` recognises it; the
///   row's `unitKey` therefore always satisfies the validator's `isKnownKey` rule.
/// - An unknown `confidence` string is `.low` (`RowConfidence(modelString:)`): a
///   misspelling can only make a row *more* visible, never less.
/// - `canonicalGuess` is carried along untouched (trimmed, nil when blank). It is
///   never applied here: `IngredientResolver.resolveRow` consults it at layer 4 only,
///   and only ever as a suggestion the user taps **Use** on.
enum ModelIngredientMapping {

    /// One input line after the merge: the (possibly refined) structured line plus the
    /// model's per-row extras. `refinedByModel` is false for lines the model skipped so
    /// tests — and a future "which rows did the model touch" debug view — can tell.
    struct MergedLine: Equatable, Sendable {
        var structured: StructuredLine
        var canonicalGuess: String?
        var confidence: RowConfidence
        var refinedByModel: Bool

        init(structured: StructuredLine,
             canonicalGuess: String? = nil,
             confidence: RowConfidence = .high,
             refinedByModel: Bool = false) {
            self.structured = structured
            self.canonicalGuess = canonicalGuess
            self.confidence = confidence
            self.refinedByModel = refinedByModel
        }
    }

    /// Merge the model's answer onto the regex result, one `MergedLine` per regex line
    /// in the same order. `model == nil` (declined / unavailable) → every line is the
    /// regex result at `.high` confidence with no guess.
    ///
    /// When two input lines are identical ("salt" in two sections) they share the one
    /// model row for that text — identical lines deserve identical treatment — and
    /// when the model returns two rows for one line the first wins, deterministically.
    static func merge(regex: [StructuredLine], model: RecipeRefinement?) -> [MergedLine] {
        guard let model = model else {
            return regex.map { MergedLine(structured: $0) }
        }
        var rowsByLine: [String: RefinedRow] = [:]
        for row in model.rows {
            let key = trimmed(row.rawLine)
            guard !key.isEmpty, rowsByLine[key] == nil else { continue }
            rowsByLine[key] = row
        }
        return regex.map { line -> MergedLine in
            guard let row = rowsByLine[trimmed(line.rawLine)] else {
                return MergedLine(structured: line)
            }
            return merged(line, with: row)
        }
    }

    /// The per-row rules, applied to one matched pair. Exposed (not private) so the
    /// rules can be read in one place; `merge` is the entry point.
    static func merged(_ line: StructuredLine, with row: RefinedRow) -> MergedLine {
        var structured = line

        // A model name replaces the regex name; a blank one leaves the regex name (and
        // an unresolved line stays unresolved — `name == rawLine` per §7.2). Once the
        // model has named the ingredient the line is no longer "nothing left".
        if let name = nonEmpty(row.name) {
            structured.name = name
            structured.isUnresolved = false
        }

        // Numbers: only refine a quantity the regex also saw, and only with a sane value.
        // `quantityText` stays what the author wrote — it is the "as written" display
        // string and the raw line has not changed.
        if line.quantity != nil, let quantity = row.quantity, quantity.isFinite, quantity >= 0 {
            structured.quantity = quantity
        }

        // Units: a spelling the table knows ("Tbsp.", "T", "cups") becomes its key and
        // keeps the model's spelling as the display text; anything else is ignored so an
        // unknown unit can never reach the row (the validator would refuse the save).
        if let unit = nonEmpty(row.unit), let key = UnitTable.key(forSpelling: unit) {
            structured.unitKey = key
            structured.unitText = unit
        }

        if let note = nonEmpty(row.note) {
            structured.note = note
        }

        return MergedLine(structured: structured,
                          canonicalGuess: nonEmpty(row.canonicalGuess),
                          confidence: RowConfidence(modelString: row.confidence),
                          refinedByModel: true)
    }

    /// The model's `warning`, trimmed; nil when blank (same rule as the workout
    /// `ModelDraftMapping.result`).
    static func warning(_ raw: String?) -> String? {
        nonEmpty(raw)
    }

    // MARK: - Pieces

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed text, or nil when nil or blank.
    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text else { return nil }
        let cleaned = trimmed(text)
        return cleaned.isEmpty ? nil : cleaned
    }
}
