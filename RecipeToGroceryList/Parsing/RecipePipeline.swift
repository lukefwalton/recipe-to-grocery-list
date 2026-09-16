import Foundation

/// The parse pipeline (spec §7): clean → structure → refine → resolve, from raw lines
/// to the `RecipeDraft` the Confirm screen edits. Every input path (paste, link,
/// photo) converges here, so one shape of line reaches the splitter and one shape of
/// draft reaches Confirm and, after the user's taps, `RecipeStore.save`.
///
/// Doctrine held end to end: the pipeline **proposes**. It never touches the store —
/// the resolver carries an in-memory `IngredientIndex` snapshot — and the model, when
/// present, is a plain `RecipeRefining?` whose rows are checked line by line by
/// `ModelIngredientMapping` before the resolver sees them. The orchestration mirrors
/// `WorkoutParserOrchestrator` at `workout-logger@5bffddfb80fc`, with the spec's two
/// departures: per-row results (one odd line never costs the others) and no
/// clarification loop (Confirm is the clarification step).
///
/// A value type on purpose: it holds a value resolver and an optional `Sendable`
/// protocol existential, so a view can build one on the main actor and `await` it
/// without sharing mutable state. (It does not declare `Sendable` itself because
/// `IngredientResolver` carries the `IngredientEmbedding` existential, which is not
/// constrained to `Sendable`; nothing here is mutated after construction.)
struct RecipePipeline {
    let resolver: IngredientResolver
    /// The on-device model, or nil when the SDK is absent, the OS is too old, or Apple
    /// Intelligence is unavailable (`RecipeParserFactory.makeRefiner()`).
    let refiner: RecipeRefining?

    init(resolver: IngredientResolver, refiner: RecipeRefining?) {
        self.resolver = resolver
        self.refiner = refiner
    }

    /// Pasted text (§5.2).
    func run(text: String, source: RecipeSource) async -> RecipeParseOutcome {
        await run(cleaned: LineCleaner.clean(text), source: source)
    }

    /// Lines that already arrived as an array — JSON-LD `recipeIngredient` (§5.1) or
    /// OCR lines (§5.3).
    func run(lines: [String], source: RecipeSource) async -> RecipeParseOutcome {
        await run(cleaned: LineCleaner.cleanLines(lines), source: source)
    }

    /// The pipeline proper. `rawLines` keeps every cleaned line, headers included, so
    /// "nothing silently dropped" holds and Confirm can interleave header dividers by
    /// `DraftRow.lineIndex`; only `.ingredient` lines become rows.
    func run(cleaned: [CleanedLine], source: RecipeSource) async -> RecipeParseOutcome {
        let rawLines: [String] = cleaned.map(\.text)
        guard !rawLines.isEmpty else { return .declined(.noLines) }

        // Ingredient lines with their index into `rawLines` (headers occupy indices too).
        var lineIndices: [Int] = []
        var ingredientLines: [String] = []
        for (index, line) in cleaned.enumerated() {
            if case .ingredient(let text) = line {
                lineIndices.append(index)
                ingredientLines.append(text)
            }
        }
        guard !ingredientLines.isEmpty else { return .declined(.noIngredientLines) }

        // §7.2 — always. The model only refines this; it can never add or remove a line.
        let regex: [StructuredLine] = ingredientLines.map { IngredientLineSplitter.split($0) }

        // §7.3 — one request per recipe, when a refiner is wired. nil = declined.
        var model: RecipeRefinement? = nil
        if let refiner = refiner {
            model = await refiner.refine(lines: ingredientLines,
                                         knownIngredients: resolver.index.canonicalNames)
        }

        // Merge (FM-free, per row) then resolve (§7.4) — the guess reaches layer 4 only.
        let merged = ModelIngredientMapping.merge(regex: regex, model: model)
        var rows: [DraftRow] = []
        rows.reserveCapacity(merged.count)
        for (position, line) in merged.enumerated() {
            rows.append(resolver.resolveRow(line.structured,
                                            lineIndex: lineIndices[position],
                                            canonicalGuess: line.canonicalGuess,
                                            confidence: line.confidence))
        }

        let draft = RecipeDraft(title: Self.title(from: source),
                                source: source,
                                rawLines: rawLines,
                                rows: rows)

        // The model's own caution when it answered; the family's "Parsed without
        // on-device AI." when it was wired but declined; nothing when there is no model
        // at all (Confirm shows `RecipeParserFactory.unavailableCopy` for that case).
        let warning: String?
        if let model = model {
            warning = ModelIngredientMapping.warning(model.warning)
        } else if refiner != nil {
            warning = RecipeParserFactory.parsedWithoutAICopy
        } else {
            warning = nil
        }

        return .draft(ParsedRecipe(draft: draft, usedOnDeviceAI: model != nil, warning: warning))
    }

    /// The source's title guess (page `name`, first pasted line, …), trimmed; empty when
    /// there is none — Confirm asks, and `RecipeDraft.canSave` stays false until it has
    /// one. The pipeline never guesses a title from the lines.
    static func title(from source: RecipeSource) -> String {
        source.titleGuess?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
