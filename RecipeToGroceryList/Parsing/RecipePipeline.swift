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

    /// Pasted text (§5.2). `selection` defaults to every line; paste and link pass
    /// `.proposedBlock` so a heading is not parsed as food.
    func run(text: String,
             source: RecipeSource,
             selection: IngredientBlock.Selection = .all,
             droppingUncertainLines: Bool = true) async -> RecipeParseOutcome {
        await run(lines: text.components(separatedBy: .newlines),
                  source: source,
                  selection: selection,
                  droppingUncertainLines: droppingUncertainLines)
    }

    /// Lines that already arrived as an array — JSON-LD `recipeIngredient` (§5.1) or
    /// OCR lines (§5.3).
    func run(lines: [String],
             source: RecipeSource,
             selection: IngredientBlock.Selection = .all,
             droppingUncertainLines: Bool = true) async -> RecipeParseOutcome {
        await finish(IngredientBlock.admit(lines, selection: selection),
                     source: source,
                     droppingUncertainLines: droppingUncertainLines)
    }

    /// Pre-cleaned lines (tests and any caller that already split headers). Treated
    /// as an ingredient list: every non-header is parsed.
    func run(cleaned: [CleanedLine], source: RecipeSource) async -> RecipeParseOutcome {
        let admitted = cleaned.map { line in
            IngredientBlock.Line(text: line.text,
                                 role: line.isSectionHeader ? .sectionHeader : .ingredient)
        }
        return await finish(admitted, source: source, droppingUncertainLines: true)
    }

    /// The pipeline proper. `rawLines` keeps every admitted line, headers included, so
    /// "nothing silently dropped" holds and Confirm can interleave header dividers by
    /// `DraftRow.lineIndex`. Excluded lines are rows that start off the list.
    private func finish(_ admitted: [IngredientBlock.Line],
                        source: RecipeSource,
                        droppingUncertainLines: Bool) async -> RecipeParseOutcome {
        let rawLines: [String] = admitted.map(\.text)
        guard !rawLines.isEmpty else { return .declined(.noLines) }

        // Ingredient lines with their index into `rawLines` (headers occupy indices too).
        var lineIndices: [Int] = []
        var ingredientLines: [String] = []
        var excludedIndices: [Int] = []
        for (index, line) in admitted.enumerated() {
            switch line.role {
            case .ingredient:
                lineIndices.append(index)
                ingredientLines.append(line.text)
            case .excluded:
                excludedIndices.append(index)
            case .sectionHeader:
                break
            }
        }
        guard !ingredientLines.isEmpty || !excludedIndices.isEmpty else {
            return .declined(.noIngredientLines)
        }

        // §7.2 — always. The model only refines this; it can never add or remove a line.
        let regex: [StructuredLine] = ingredientLines.map { IngredientLineSplitter.split($0) }

        // §7.3 — one request per recipe, when a refiner is wired and there is
        // something for it to read. Headings and lines left off the list are not sent.
        var model: RecipeRefinement? = nil
        if let refiner = refiner, !ingredientLines.isEmpty {
            model = await refiner.refine(lines: ingredientLines,
                                         knownIngredients: resolver.index.canonicalNames)
        }

        // Merge (FM-free, per row) then resolve (§7.4). The written name is what
        // gets matched; the guess is only a suggestion.
        let merged = ModelIngredientMapping.merge(regex: regex, model: model)
        var rows: [DraftRow] = []
        rows.reserveCapacity(merged.count + excludedIndices.count)
        for (position, line) in merged.enumerated() {
            rows.append(resolver.resolveRow(line.structured,
                                            lineIndex: lineIndices[position],
                                            canonicalGuess: line.canonicalGuess,
                                            confidence: line.confidence,
                                            dropUncertain: droppingUncertainLines))
        }
        for index in excludedIndices {
            let text = admitted[index].text
            rows.append(DraftRow(lineIndex: index,
                                 rawLine: text,
                                 name: text,
                                 resolution: .none,
                                 confidence: .low,
                                 isRemoved: true))
        }
        rows.sort { $0.lineIndex < $1.lineIndex }

        let draft = RecipeDraft(title: Self.title(from: source),
                                source: source,
                                rawLines: rawLines,
                                rows: rows)

        // The model's own caution when it answered; the family's "Parsed without
        // on-device AI." when it was wired but declined; nothing when there is no model
        // at all (Confirm shows `RecipeParserFactory.unavailableCopy` for that case).
        let warning: String?
        if ingredientLines.isEmpty {
            warning = nil
        } else if let model = model {
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
