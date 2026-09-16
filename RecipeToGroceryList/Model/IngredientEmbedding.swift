import Foundation

/// Layer 3 of the resolution stack (spec §7.4): on-device semantic embeddings,
/// reached only when fuzzy (layer 2) is low-confidence. Behind a protocol so **no
/// `NaturalLanguage` symbol leaks into always-compiled code** — the unit tests build
/// and run without it. The real implementation
/// (`NLContextualEmbeddingIngredientMatcher`) lives entirely inside
/// `#if canImport(NaturalLanguage)`; tests drive a fake.
///
/// Port of `Model/ExerciseEmbedding.swift` at `workout-logger@5bffddfb80fc`, renamed.
/// Same doctrine: like every layer ≥ 2 it **proposes** a candidate the user confirms —
/// it never auto-applies and never merges two distinct canonicals. It is
/// **opportunistic**: any failure (assets not downloaded, simulator, ineligible
/// device) falls through to fuzzy/LLM, and it must never block the UI.
protocol IngredientEmbedding {
    /// Whether embeddings are usable *right now* — the model assets are loaded and a
    /// vector can be produced. False on the simulator, an ineligible device, or before
    /// the system assets finish downloading. Callers check this and fall through.
    var isReady: Bool { get }

    /// A single fixed-length vector for a phrase — the gated implementation embeds
    /// each token and mean-pools them. nil when `isReady` is false or the phrase
    /// can't be embedded. Synchronous and non-blocking: it returns a cached/ready
    /// result or nil, never waits on a download.
    func vector(for text: String) -> [Double]?
}

/// The stand-in used when `NaturalLanguage` isn't compiled in or the device can't
/// load embeddings: never ready, so the resolution stack simply stops at fuzzy. This
/// is the shippable bar — embeddings are a bonus rung (§7.6 runs without them).
struct NoopEmbedding: IngredientEmbedding {
    var isReady: Bool { false }
    func vector(for text: String) -> [Double]? { nil }
}

/// Picks the real matcher when the SDK is present and the no-op otherwise. The `#if`
/// is the only place the two worlds meet; callers just get an `IngredientEmbedding`.
enum IngredientEmbeddingFactory {
    static func make() -> IngredientEmbedding {
        #if canImport(NaturalLanguage)
        if let matcher = NLContextualEmbeddingIngredientMatcher.makeIfAvailable() {
            return matcher
        }
        return NoopEmbedding()
        #else
        return NoopEmbedding()
        #endif
    }
}

/// Pure vector math for the semantic layer — cosine similarity and mean-pooling —
/// kept Foundation-only and unit-tested so the ranking logic is verifiable here even
/// though the real embeddings aren't. (Copied from the workout app's `EmbeddingMath`.)
enum EmbeddingMath {
    /// Cosine similarity of two equal-length vectors, in [-1, 1]. 0 when either is a
    /// zero vector or lengths differ (degenerate → "not similar", never a crash).
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Mean-pool per-token vectors into one. Empty input (or all-empty tokens) → nil.
    /// Ragged token vectors are rejected (nil) rather than silently truncated.
    static func meanPool(_ tokenVectors: [[Double]]) -> [Double]? {
        let vectors = tokenVectors.filter { !$0.isEmpty }
        guard let width = vectors.first?.count, vectors.allSatisfy({ $0.count == width }) else { return nil }
        var sums = [Double](repeating: 0, count: width)
        for vector in vectors {
            for i in 0..<width { sums[i] += vector[i] }
        }
        let count = Double(vectors.count)
        return sums.map { $0 / count }
    }
}

/// The canonical registry embedded once per index — layer 3's ranking input
/// (the workout app's `SemanticSuggester.Candidate` list plus the cache that
/// `TodayModel.semanticCandidates()` kept, folded into one value). Build it when
/// the index changes (a save can add a canonical) and when embeddings become ready;
/// `build` returns nil while they are not, so a caller never caches an empty set
/// that would freeze layer 3 off (`docs/learnings/023-embeddings.md` in the workout
/// repo, "cache staleness").
struct SemanticCandidateSet: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let ingredientID: Int64
        let canonicalName: String
        let vector: [Double]
    }

    let candidates: [Candidate]

    init(candidates: [Candidate]) {
        self.candidates = candidates
    }

    /// Embeds every canonical name once. nil unless the embedding is ready; entries
    /// whose name cannot be embedded are skipped rather than failing the whole set.
    static func build(index: IngredientIndex, embedding: IngredientEmbedding) -> SemanticCandidateSet? {
        guard embedding.isReady else { return nil }
        let candidates: [Candidate] = index.entries.compactMap { entry -> Candidate? in
            guard let vector = embedding.vector(for: entry.canonicalName) else { return nil }
            return Candidate(ingredientID: entry.id, canonicalName: entry.canonicalName, vector: vector)
        }
        return SemanticCandidateSet(candidates: candidates)
    }

    /// Ranked semantic candidates for `query`, best first, capped at `limit`, all at
    /// or above `threshold` and marked `via: .embedding`. Empty when embeddings aren't
    /// ready, the query can't be embedded, or nothing clears the threshold.
    func suggestions(for query: String, embedding: IngredientEmbedding, threshold: Double, limit: Int) -> [IngredientSuggestion] {
        guard limit > 0, embedding.isReady, let queryVector = embedding.vector(for: query) else { return [] }
        let ranked: [IngredientSuggestion] = candidates.compactMap { candidate -> IngredientSuggestion? in
            let score = EmbeddingMath.cosineSimilarity(queryVector, candidate.vector)
            guard score >= threshold else { return nil }
            return IngredientSuggestion(ingredientID: candidate.ingredientID,
                                        canonicalName: candidate.canonicalName,
                                        score: score,
                                        via: .embedding)
        }
        .sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.canonicalName < b.canonicalName   // deterministic tie-break
        }
        return Array(ranked.prefix(limit))
    }
}
