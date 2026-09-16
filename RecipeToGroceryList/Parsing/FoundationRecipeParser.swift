#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// Stage 7.3 of the pipeline: the on-device LLM, asked **once per recipe** to refine
/// the regex splitter's reading of every ingredient line. The entire file is wrapped in
/// `#if canImport(FoundationModels)` so not one FM symbol — `SystemLanguageModel`,
/// `LanguageModelSession`, `@Generable`, `@Guide` — can leak into always-compiled
/// code. It conforms to the FM-free `RecipeRefining` protocol; `RecipePipeline` and
/// `AppModel` only ever see that protocol, and `RecipeParserFactory` is the only place
/// that names this type.
///
/// No write power (§1): it returns **proposals** as plain `RefinedRow`s, or nil. The
/// FM-free, unit-tested `ModelIngredientMapping` then checks every row against the
/// regex result (no invented lines, no invented quantities, no unknown units), the
/// resolver consults `canonicalGuess` only as a layer-4 *suggestion*, the user confirms,
/// `RecipeStore` writes. Ported from `WorkoutChatLog/Parsing/FoundationWorkoutParser.swift`
/// at `workout-logger@5bffddfb80fc`; the two departures are the spec's (§3): per-row
/// results and no clarification kind.
///
/// NOT COMPILED HERE (Linux, no FoundationModels SDK). The symbol names below —
/// `SystemLanguageModel.default.availability`, `LanguageModelSession(instructions:)`,
/// `respond(to:generating:)`, `Response.content`, `@Generable`/`@Guide` on `let`
/// properties — and the `iOS 26.0` floor follow the workout adapter and the spec and
/// **must be verified against the installed SDK in Xcode**; the SDK is the source of
/// truth. The `foundation-models-guard` CI job (`macos-26`) is what compiles this file.
@available(iOS 26.0, *)
struct FoundationRecipeParser: RecipeRefining {

    /// The compile gate proves the SDK exists; this proves the on-device model is
    /// actually usable right now (eligible device, Apple Intelligence enabled, model
    /// downloaded). Anything other than `.available` → treat as no model.
    static func isModelAvailable() -> Bool {
        switch SystemLanguageModel.default.availability {
        case .available:
            return true
        default:
            // `.unavailable(_)` and any future case → unavailable. A coarse switch on
            // purpose: a new reason must never read as "available".
            return false
        }
    }

    /// One `LanguageModelSession` per recipe (§7.3: per recipe, not per line). The
    /// known-ingredient list travels in the *instructions*, the user's lines in the
    /// *prompt* — the documented FM pattern, which also keeps a pasted line from
    /// rewriting the rules.
    func refine(lines: [String], knownIngredients: [String]) async -> RecipeRefinement? {
        guard !lines.isEmpty, Self.isModelAvailable() else { return nil }

        let session = LanguageModelSession(instructions: Self.instructions(knownIngredients: knownIngredients))
        do {
            let response = try await session.respond(to: Self.prompt(lines: lines),
                                                     generating: ModelRecipeParse.self)
            return Self.refinement(from: response.content)
        } catch {
            // A model error (context overflow, guardrail refusal, decode failure,
            // timeout) is a decline: every line keeps its regex result and the UI says
            // "Parsed without on-device AI" — never a crash, never a fabricated row.
            // Surface it in DEBUG so an SDK/integration regression is not
            // indistinguishable from the model simply passing on a recipe. Log the
            // error only — never the user's lines — so nothing identifiable is recorded.
            #if DEBUG
            print("[FoundationRecipeParser] model refine failed, falling back to the regex splitter: \(error)")
            #endif
            return nil
        }
    }

    // MARK: - Prompt

    /// The rules. Each one maps to a check `ModelIngredientMapping` enforces anyway
    /// (the model is asked to behave; the mapping makes sure it did).
    static func instructions(knownIngredients: [String]) -> String {
        let known = knownIngredients.isEmpty
            ? "(none yet)"
            : knownIngredients.joined(separator: ", ")
        return """
        You clean up the ingredient lines of one recipe for a grocery list. You never write \
        anything: you only propose, and the user confirms and can edit every field before \
        anything is saved.

        Each line of the prompt is one ingredient line, exactly as the user gave it. Return \
        one row per line, in the same order. Set rawLine to the input line unchanged, \
        character for character — it is how each row is matched back to its line. Never add \
        a row for a line that is not in the input, and never merge or split lines. If a line \
        is not an ingredient (a heading, a step, a note), still return its row with your best \
        reading and confidence "low".

        For each row:
        - name: the ingredient as written, without the quantity, unit and preparation notes \
        ("veggie stock" for "2 cups veggie stock, warmed").
        - canonicalGuess: the best canonical grocery name for that ingredient. Prefer one of \
        the known ingredients below whenever one clearly fits ("vegetable broth" for "veggie \
        stock"); if none fits, propose a short, plain grocery name of your own.
        - quantity: the number the line states, or nil when it states none. Never invent a \
        quantity. For a range such as "2-3" use the lower bound, 2.
        - unit: the unit exactly as written ("cups", "Tbsp", "g"), or nil when there is none.
        - note: preparation or usage text such as "diced", "divided" or "for serving", or nil.
        - confidence: "high" when the line is one unambiguous ingredient; "medium" when your \
        reading is a reasonable guess; "low" when you are unsure or the line is not an \
        ingredient.

        Set warning to one short sentence if some lines were not ingredients or could not be \
        read; otherwise leave it empty.

        Known ingredients: \(known)
        """
    }

    /// The user's lines, one per line, nothing else — the instructions already say how
    /// to read them.
    static func prompt(lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    // MARK: - Mapping (a dumb copy; the defensive logic is FM-free ModelIngredientMapping)

    /// Copies the `@Generable` response into plain `RefinedRow`s field for field. No
    /// checks here on purpose: everything that can be wrong with a row is caught, and
    /// unit-tested, in `ModelIngredientMapping.merge`.
    static func refinement(from parse: ModelRecipeParse) -> RecipeRefinement {
        let rows: [RefinedRow] = parse.rows.map { row -> RefinedRow in
            RefinedRow(rawLine: row.rawLine,
                       name: row.name,
                       canonicalGuess: row.canonicalGuess,
                       quantity: row.quantity,
                       unit: row.unit,
                       note: row.note,
                       confidence: row.confidence)
        }
        return RecipeRefinement(rows: rows, warning: ModelIngredientMapping.warning(parse.warning))
    }
}

// MARK: - @Generable response shape (spec §7.3, verbatim)

@available(iOS 26.0, *)
@Generable
struct ModelIngredientRow {
    @Guide(description: "The input line, unchanged.")
    let rawLine: String
    @Guide(description: "Ingredient name as written, cleaned of quantity, unit, and prep notes.")
    let name: String
    @Guide(description: "Best canonical grocery name for this ingredient, e.g. 'vegetable broth' for 'veggie stock'.")
    let canonicalGuess: String
    @Guide(description: "Numeric amount if the line states one; otherwise nil. Never invent one.")
    let quantity: Double?
    @Guide(description: "Unit exactly as written, or nil.")
    let unit: String?
    @Guide(description: "Preparation or usage note such as 'diced' or 'divided', or nil.")
    let note: String?
    @Guide(description: "high if the line is an unambiguous single ingredient; medium if a reasonable guess; low if unsure or the line is not an ingredient.")
    let confidence: String   // high | medium | low
}

@available(iOS 26.0, *)
@Generable
struct ModelRecipeParse {
    let rows: [ModelIngredientRow]
    @Guide(description: "Short warning if some lines were not ingredients or could not be read; otherwise empty.")
    let warning: String
}
#endif
