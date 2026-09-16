import Foundation

/// The outcome of one layer hit (spec §7.4): which canonical, which layer, and the
/// layer's score (1 for the deterministic layers, the similarity for fuzzy and
/// embedding). `resolution` is what `recipe_ingredients.resolution` records.
struct IngredientResolution: Equatable, Sendable {
    let ingredientID: Int64
    let resolution: RowResolution
    let score: Double
}

/// The resolution stack (§7.4): per row, first hit wins, in the order
/// exact (0) → alias (1) → loose key (1.5) → fuzzy (2) → embedding (3), with the
/// LLM's `canonicalGuess` consulted only at layer 4 and only as a *suggestion*.
///
/// Ported from the workout app's stack at `workout-logger@5bffddfb80fc`
/// (`WorkoutStore+Exercises.swift` `resolveExercise` + `suggestExercisesFuzzy`;
/// `Features/TodayModel.swift` `suggestions(for:)` for the fuzzy → semantic
/// escalation). Same doctrine: every layer ≥ 2 **proposes**, the user confirms in
/// Confirm, the store writes; two existing canonicals are never auto-merged; and the
/// semantic layer is opportunistic — additive, never displacing a fuzzy hit, and
/// silent when embeddings are not ready.
///
/// Thresholds start at the workout values (0.78 / 0.85) and are recalibrated on the
/// golden corpus (§11, §13); they are instance properties so tests and a future
/// Settings toggle can vary them without touching the algorithm.
struct IngredientResolver {
    let index: IngredientIndex
    /// Canonical vectors embedded once per index (`SemanticCandidateSet.build`).
    /// nil turns layer 3 off entirely — the shippable bar is layers 0–2.
    var semantic: SemanticCandidateSet?
    /// Embeds the query when `semantic != nil`.
    var embedding: IngredientEmbedding
    var fuzzyThreshold: Double = IngredientResolver.defaultFuzzyThreshold
    var semanticThreshold: Double = IngredientResolver.defaultSemanticThreshold
    /// Layer 3 is consulted only while the best fuzzy score is below this bar.
    var semanticEscalationBar: Double = IngredientResolver.defaultSemanticEscalationBar

    static let defaultFuzzyThreshold = 0.78
    static let defaultSemanticThreshold = 0.85
    static let defaultSemanticEscalationBar = 0.85
    /// How many near misses ride along for the "change ingredient" picker.
    static let alternativesLimit = 3

    init(index: IngredientIndex, embedding: IngredientEmbedding = NoopEmbedding(), semantic: SemanticCandidateSet? = nil) {
        self.index = index
        self.embedding = embedding
        self.semantic = semantic
    }

    // MARK: - Layers 0–1.5

    /// Exact → alias → loose key, first hit wins. Also what layer 4 runs on the model's
    /// `canonicalGuess`. Blank input resolves to nothing.
    func resolveDeterministic(_ name: String) -> IngredientResolution? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let id = index.exactMatch(trimmed) {
            return IngredientResolution(ingredientID: id, resolution: .exact, score: 1)
        }
        if let id = index.aliasMatch(trimmed) {
            return IngredientResolution(ingredientID: id, resolution: .alias, score: 1)
        }
        if let id = index.looseMatch(trimmed) {
            return IngredientResolution(ingredientID: id, resolution: .loose, score: 1)
        }
        return nil
    }

    // MARK: - Layer 2

    /// Fuzzy candidates at or above `fuzzyThreshold`, best first. Each entry scores as
    /// the best of its canonical name and aliases (`FuzzyMatch.similarity`). Ties break
    /// by the name closest in length to the query, then by name — the workout app's
    /// rule ("Bench Press" before "Incline Bench Press"). Proposals only.
    func fuzzySuggestions(for name: String, limit: Int = IngredientResolver.alternativesLimit) -> [IngredientSuggestion] {
        guard limit > 0 else { return [] }
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !IngredientNormalizer.normalize(query).isEmpty else { return [] }
        var found: [IngredientSuggestion] = []
        for entry in index.entries {
            var best = FuzzyMatch.similarity(query, entry.canonicalName)
            for alias in entry.aliases {
                best = max(best, FuzzyMatch.similarity(query, alias))
            }
            if best >= fuzzyThreshold {
                found.append(IngredientSuggestion(ingredientID: entry.id,
                                                  canonicalName: entry.canonicalName,
                                                  score: best,
                                                  via: .fuzzy))
            }
        }
        let queryLength = query.count
        found.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let da = abs(a.canonicalName.count - queryLength)
            let db = abs(b.canonicalName.count - queryLength)
            if da != db { return da < db }
            return a.canonicalName < b.canonicalName
        }
        return Array(found.prefix(limit))
    }

    // MARK: - The stack

    /// Layers 0 → 1 → 1.5 → 2 → 3 for one cleaned name. The hit (if any) carries the
    /// layer that produced it; `alternatives` are near misses for the picker.
    ///
    /// Layer 3 runs only when the best fuzzy score is below `semanticEscalationBar`.
    /// With no fuzzy hit, a semantic candidate at or above `semanticThreshold` becomes
    /// an `.embedding` hit; with a fuzzy hit, semantic candidates are appended to the
    /// alternatives and never displace it (`TodayModel.suggestions(for:)`).
    func resolve(_ name: String) -> (hit: IngredientResolution?, alternatives: [IngredientSuggestion]) {
        if let deterministic = resolveDeterministic(name) {
            return (deterministic, [])
        }

        let fuzzy = fuzzySuggestions(for: name, limit: Self.alternativesLimit + 1)
        var hit: IngredientResolution? = nil
        var alternatives: [IngredientSuggestion] = []
        if let best = fuzzy.first {
            hit = IngredientResolution(ingredientID: best.ingredientID, resolution: .fuzzy, score: best.score)
            alternatives = Array(fuzzy.dropFirst())
        }

        let bestFuzzyScore = fuzzy.first?.score ?? 0
        if bestFuzzyScore < semanticEscalationBar, let semantic = semantic {
            let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let semanticHits = semantic.suggestions(for: query,
                                                    embedding: embedding,
                                                    threshold: semanticThreshold,
                                                    limit: Self.alternativesLimit + 1)
            if let existing = hit {
                // Additive: new canonicals only, after the fuzzy list, never displacing.
                var seen = Set(alternatives.map(\.ingredientID))
                seen.insert(existing.ingredientID)
                for suggestion in semanticHits.prefix(Self.alternativesLimit) where !seen.contains(suggestion.ingredientID) {
                    alternatives.append(suggestion)
                    seen.insert(suggestion.ingredientID)
                }
            } else if let best = semanticHits.first {
                hit = IngredientResolution(ingredientID: best.ingredientID, resolution: .embedding, score: best.score)
                alternatives = Array(semanticHits.dropFirst().prefix(Self.alternativesLimit))
            }
        }
        return (hit, alternatives)
    }

    // MARK: - Rows

    /// Builds the Confirm row for one structured line (§7.4 + §7.5):
    /// - a hit at layers 0–3 sets `ingredient`, `ingredientName` and `resolution`
    ///   (fuzzy/embedding rows show as highlighted through `DraftRow.state`);
    /// - with no hit, layer 4 runs `resolveDeterministic` on the model's
    ///   `canonicalGuess`; a hit there is only a `.llm` **suggestion** — the row's
    ///   `ingredient` stays nil until the user taps Use, because the model never
    ///   writes an alias (§7.5);
    /// - otherwise the row is `.none` — a new ingredient that needs a tap.
    ///
    /// The row is never resolved from the guess directly, and a low confidence never
    /// removes a deterministic hit; confidence only affects how the row is shown.
    func resolveRow(_ line: StructuredLine, lineIndex: Int, canonicalGuess: String?, confidence: RowConfidence) -> DraftRow {
        let outcome = resolve(line.name)
        var row = DraftRow(lineIndex: lineIndex,
                           rawLine: line.rawLine,
                           name: line.name,
                           quantity: line.quantity,
                           unitKey: line.unitKey,
                           unitText: line.unitText,
                           note: line.note,
                           confidence: confidence,
                           alternatives: outcome.alternatives)
        if let hit = outcome.hit {
            row.ingredient = .existing(hit.ingredientID)
            row.ingredientName = index.entry(id: hit.ingredientID)?.canonicalName
            row.resolution = hit.resolution
            return row
        }
        row.resolution = .none
        if let guess = canonicalGuess?.trimmingCharacters(in: .whitespacesAndNewlines),
           !guess.isEmpty,
           let guessed = resolveDeterministic(guess),
           let entry = index.entry(id: guessed.ingredientID) {
            row.suggestion = IngredientSuggestion(ingredientID: entry.id,
                                                  canonicalName: entry.canonicalName,
                                                  score: guessed.score,
                                                  via: .llm)
        }
        return row
    }
}
