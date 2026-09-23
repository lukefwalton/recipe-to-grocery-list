import XCTest
@testable import RecipeToGroceryList

/// A scripted `IngredientEmbedding` for the layer-3 tests — never imports
/// `NaturalLanguage`. Returns fixed fixture vectors by phrase, so cosine ranking is
/// exercised deterministically without the real model, and records every phrase it
/// was asked to embed so tests can prove when layer 3 was *not* consulted.
/// (Port of the workout app's `FakeEmbedding` in `SemanticSuggesterTests.swift`.)
final class FakeEmbedding: IngredientEmbedding {
    var ready: Bool
    var vectors: [String: [Double]]
    private(set) var requests: [String] = []

    init(ready: Bool = true, vectors: [String: [Double]] = [:]) {
        self.ready = ready
        self.vectors = vectors
    }

    var isReady: Bool { ready }

    func vector(for text: String) -> [Double]? {
        requests.append(text)
        return vectors[text]
    }
}

/// Layer 3 (§7.4): cosine math, mean-pooling and the candidate set's
/// propose-and-confirm behaviour — all with a fake embedding. The real
/// `NLContextualEmbedding` behaviour is a human-on-device acceptance step.
final class SemanticMatchingTests: XCTestCase {

    // MARK: - Pure vector math

    func testCosineSimilarity() {
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1, accuracy: 1e-9)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [0, 1]), 0, accuracy: 1e-9)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 0], [-1, 0]), -1, accuracy: 1e-9)
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([0, 0], [1, 1]), 0, "zero vector → 0, not a crash")
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([1, 2], [1, 2, 3]), 0, "length mismatch → 0")
        XCTAssertEqual(EmbeddingMath.cosineSimilarity([], []), 0)
    }

    func testMeanPool() {
        XCTAssertEqual(EmbeddingMath.meanPool([[2, 4], [4, 8]]), [3, 6])
        XCTAssertEqual(EmbeddingMath.meanPool([[1, 1]]), [1, 1])
        XCTAssertNil(EmbeddingMath.meanPool([]), "no tokens → nil")
        XCTAssertNil(EmbeddingMath.meanPool([[], []]), "only empty tokens → nil")
        XCTAssertNil(EmbeddingMath.meanPool([[1, 2], [1, 2, 3]]), "ragged vectors → nil, never truncated")
    }

    // MARK: - Noop

    func testNoopEmbeddingIsNeverReady() {
        XCTAssertFalse(NoopEmbedding().isReady)
        XCTAssertNil(NoopEmbedding().vector(for: "anything"))
    }

    // MARK: - Candidate set

    private let index = IngredientIndex(entries: [
        IngredientIndexEntry(id: 1, canonicalName: "Vegetable broth", category: .pantry),
        IngredientIndexEntry(id: 2, canonicalName: "Chicken broth", category: .pantry),
        IngredientIndexEntry(id: 3, canonicalName: "Butter", category: .dairy),
    ])

    func testBuildIsNilWhenEmbeddingIsNotReady() {
        let embedding = FakeEmbedding(ready: false, vectors: ["Vegetable broth": [1, 0]])
        XCTAssertNil(SemanticCandidateSet.build(index: index, embedding: embedding))
        XCTAssertTrue(embedding.requests.isEmpty, "nothing is embedded while not ready")
    }

    func testBuildEmbedsEachCanonicalOnceAndSkipsUnembeddable() throws {
        let embedding = FakeEmbedding(vectors: ["Vegetable broth": [1, 0], "Chicken broth": [0.9, 0.1]])
        let set = try XCTUnwrap(SemanticCandidateSet.build(index: index, embedding: embedding))
        XCTAssertEqual(set.candidates.map(\.ingredientID), [1, 2], "Butter had no vector and is skipped, not fatal")
        XCTAssertEqual(set.candidates.first?.canonicalName, "Vegetable broth")
        XCTAssertEqual(set.candidates.first?.vector, [1, 0])
        XCTAssertEqual(embedding.requests, ["Vegetable broth", "Chicken broth", "Butter"], "each name embedded exactly once")
    }

    func testBuildOnAnEmptyIndexIsAnEmptySet() throws {
        let set = try XCTUnwrap(SemanticCandidateSet.build(index: .empty, embedding: FakeEmbedding()))
        XCTAssertTrue(set.candidates.isEmpty)
        XCTAssertTrue(set.suggestions(for: "x", embedding: FakeEmbedding(vectors: ["x": [1]]), threshold: 0, limit: 3).isEmpty)
    }

    func testSuggestionsRankAboveThresholdViaEmbedding() {
        // "stock for soup" embeds near both broths, far from Butter.
        let embedding = FakeEmbedding(vectors: [
            "Vegetable broth": [1.0, 0.0, 0.0],
            "Chicken broth": [0.9, 0.1, 0.0],
            "Butter": [0.0, 1.0, 0.0],
            "stock for soup": [0.95, 0.05, 0.0],
        ])
        let set = SemanticCandidateSet.build(index: index, embedding: embedding)!
        let suggestions = set.suggestions(for: "stock for soup", embedding: embedding, threshold: 0.85, limit: 3)
        XCTAssertEqual(suggestions.map(\.canonicalName), ["Vegetable broth", "Chicken broth"])
        XCTAssertTrue(suggestions.allSatisfy { $0.via == .embedding }, "layer 3 marks its origin")
        XCTAssertTrue(suggestions.allSatisfy { $0.score >= 0.85 })
        XCTAssertFalse(suggestions.contains { $0.canonicalName == "Butter" }, "below-threshold is excluded")
    }

    func testSuggestionsAreCappedAndDeterministicallyOrdered() {
        let embedding = FakeEmbedding(vectors: [
            "Vegetable broth": [1.0, 0.0],
            "Chicken broth": [1.0, 0.0],      // exact tie with Vegetable broth → name order
            "Butter": [0.99, 0.14],
            "q": [1.0, 0.0],
        ])
        let set = SemanticCandidateSet.build(index: index, embedding: embedding)!
        let all = set.suggestions(for: "q", embedding: embedding, threshold: 0.5, limit: 10)
        XCTAssertEqual(all.map(\.canonicalName), ["Chicken broth", "Vegetable broth", "Butter"])
        XCTAssertEqual(set.suggestions(for: "q", embedding: embedding, threshold: 0.5, limit: 2).count, 2)
        XCTAssertTrue(set.suggestions(for: "q", embedding: embedding, threshold: 0.5, limit: 0).isEmpty)
    }

    func testNotReadyOrUnembeddableQueryYieldsNothing() {
        let vectors: [String: [Double]] = ["Vegetable broth": [1, 0], "q": [1, 0]]
        let ready = FakeEmbedding(vectors: vectors)
        let set = SemanticCandidateSet.build(index: index, embedding: ready)!
        XCTAssertFalse(set.suggestions(for: "q", embedding: ready, threshold: 0.8, limit: 3).isEmpty, "sanity: works when ready")

        let notReady = FakeEmbedding(ready: false, vectors: vectors)
        XCTAssertTrue(set.suggestions(for: "q", embedding: notReady, threshold: 0.8, limit: 3).isEmpty,
                      "the shippable bar: not ready → silent, caller keeps fuzzy")
        XCTAssertTrue(set.suggestions(for: "unknown phrase", embedding: ready, threshold: 0.8, limit: 3).isEmpty,
                      "no vector for the query → silent")
    }

    func testCandidateSetEquality() {
        let a = SemanticCandidateSet(candidates: [.init(ingredientID: 1, canonicalName: "A", vector: [1])])
        let b = SemanticCandidateSet(candidates: [.init(ingredientID: 1, canonicalName: "A", vector: [1])])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, SemanticCandidateSet(candidates: []))
    }
}
