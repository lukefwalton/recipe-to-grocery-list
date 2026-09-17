import XCTest
@testable import RecipeToGroceryList

/// §7.4: the index's deterministic layers, the fuzzy layer, the fuzzy → semantic
/// escalation, and `resolveRow`'s DraftRow construction. Fuzzy scores asserted here
/// were computed with the Python port of the metric first (`fuzzy_check.py`).
final class IngredientResolverTests: XCTestCase {

    /// A hand-built registry with the food-specific traps (§7.4) present as *separate*
    /// canonicals, aliases normalized exactly as the store stores them.
    private static func entry(_ id: Int64, _ name: String, _ category: IngredientCategory, _ aliases: [String] = []) -> IngredientIndexEntry {
        IngredientIndexEntry(id: id, canonicalName: name, category: category,
                             aliases: aliases.map(IngredientNormalizer.normalize))
    }

    private let index = IngredientIndex(entries: [
        IngredientResolverTests.entry(1, "Vegetable broth", .pantry, ["veggie broth", "vegetable stock", "veggie stock"]),
        IngredientResolverTests.entry(2, "Chicken broth", .pantry, ["chicken stock"]),
        IngredientResolverTests.entry(3, "Chicken", .meat),
        IngredientResolverTests.entry(4, "Sour cream", .dairy),
        IngredientResolverTests.entry(5, "Heavy cream", .dairy, ["heavy whipping cream"]),
        IngredientResolverTests.entry(6, "Paprika", .pantry),
        IngredientResolverTests.entry(7, "Smoked paprika", .pantry),
        IngredientResolverTests.entry(8, "Tomato", .produce, ["roma tomato", "plum tomatoes"]),
        IngredientResolverTests.entry(9, "Scallion", .produce, ["green onion", "spring onions"]),
        IngredientResolverTests.entry(10, "Chickpea", .pantry, ["garbanzo beans"]),
        IngredientResolverTests.entry(11, "Garlic", .produce),
        IngredientResolverTests.entry(12, "Garlic powder", .pantry),
        IngredientResolverTests.entry(13, "Bell pepper", .produce, ["capsicum"]),
        IngredientResolverTests.entry(14, "Mozzarella", .dairy),
        IngredientResolverTests.entry(15, "Cream", .dairy),
    ])

    private var resolver: IngredientResolver { IngredientResolver(index: index) }

    // MARK: - IngredientIndex

    func testEntryLookupAndCanonicalNames() {
        XCTAssertEqual(index.entry(id: 9)?.canonicalName, "Scallion")
        XCTAssertEqual(index.entry(id: 9)?.category, .produce)
        XCTAssertEqual(index.entry(id: 9)?.aliases, ["green onion", "spring onion"], "aliases are stored normalized")
        XCTAssertNil(index.entry(id: 999))
        XCTAssertEqual(index.canonicalNames.first, "Bell pepper")
        XCTAssertEqual(index.canonicalNames.count, 15)
        XCTAssertEqual(index.canonicalNames, index.canonicalNames.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertTrue(IngredientIndex.empty.isEmpty)
        XCTAssertNil(IngredientIndex.empty.exactMatch("Chicken"))
    }

    func testExactMatchIgnoresCaseAndWhitespace() {
        XCTAssertEqual(index.exactMatch("Vegetable broth"), 1)
        XCTAssertEqual(index.exactMatch("VEGETABLE  BROTH"), 1)
        XCTAssertEqual(index.exactMatch("  chicken "), 3)
        XCTAssertNil(index.exactMatch("chickens"), "layer 0 is exact; plurals are layer 1.5's job")
        XCTAssertNil(index.exactMatch(""))
    }

    func testAliasMatchNormalizesTheQuery() {
        XCTAssertEqual(index.aliasMatch("veggie stock"), 1)
        XCTAssertEqual(index.aliasMatch("Veggie Stocks"), 1)
        XCTAssertEqual(index.aliasMatch("the Green Onions,"), 9)
        XCTAssertEqual(index.aliasMatch("garbanzo bean"), 10)
        XCTAssertNil(index.aliasMatch("Chicken"), "canonical names are not aliases")
        XCTAssertEqual(index.aliasOwner(normalizedAlias: "veggie stock"), 1)
        XCTAssertNil(index.aliasOwner(normalizedAlias: "Veggie Stock"), "aliasOwner expects an already-normalized alias")
    }

    func testLooseMatchJoinsSpacingAndPlurals() {
        XCTAssertEqual(index.looseMatch("chick peas"), 10)
        XCTAssertEqual(index.looseMatch("Green-onion"), 9, "through an alias's loose key")
        XCTAssertEqual(index.looseMatch("Bell  Peppers"), 13)
        XCTAssertNil(index.looseMatch("smoked paprikas garnish"))
        XCTAssertNil(index.looseMatch(""))
    }

    func testAmbiguousLooseKeyResolvesToNothing() {
        let ambiguous = IngredientIndex(entries: [
            Self.entry(21, "Chick pea", .pantry),
            Self.entry(22, "Chickpea", .pantry),
        ])
        XCTAssertNil(ambiguous.looseMatch("chick peas"), "two different canonicals share the key → never auto-merged")
        XCTAssertEqual(ambiguous.exactMatch("chickpea"), 22, "layer 0 still works")
        XCTAssertEqual(ambiguous.exactMatch("chick pea"), 21)
    }

    func testSameOwnerSharingALooseKeyIsNotAmbiguous() {
        let shared = IngredientIndex(entries: [Self.entry(31, "Chickpea", .pantry, ["chick peas", "chick-pea"])])
        XCTAssertEqual(shared.looseMatch("chickpeas"), 31)
    }

    func testIndexEqualityIsOverEntries() {
        XCTAssertEqual(index, IngredientIndex(entries: index.entries))
        XCTAssertNotEqual(index, IngredientIndex.empty)
    }

    // MARK: - Layers 0–1.5

    func testDeterministicLayersInOrder() {
        XCTAssertEqual(resolver.resolveDeterministic("Vegetable broth"),
                       IngredientResolution(ingredientID: 1, resolution: .exact, score: 1))
        XCTAssertEqual(resolver.resolveDeterministic("veggie stock"),
                       IngredientResolution(ingredientID: 1, resolution: .alias, score: 1))
        XCTAssertEqual(resolver.resolveDeterministic("chick peas"),
                       IngredientResolution(ingredientID: 10, resolution: .loose, score: 1))
        XCTAssertNil(resolver.resolveDeterministic("mozzarela"))
        XCTAssertNil(resolver.resolveDeterministic("   "))
    }

    func testResolveStopsAtTheFirstHit() {
        let exact = resolver.resolve("Chicken")
        XCTAssertEqual(exact.hit?.resolution, .exact)
        XCTAssertEqual(exact.hit?.ingredientID, 3)
        XCTAssertTrue(exact.alternatives.isEmpty, "deterministic hits carry no near misses")

        let alias = resolver.resolve("Spring Onions")
        XCTAssertEqual(alias.hit, IngredientResolution(ingredientID: 9, resolution: .alias, score: 1))
    }

    // MARK: - Layer 2

    func testFuzzyHitsAreHighlightedProposals() {
        let outcome = resolver.resolve("mozzarela")
        XCTAssertEqual(outcome.hit?.ingredientID, 14)
        XCTAssertEqual(outcome.hit?.resolution, .fuzzy)
        XCTAssertEqual(outcome.hit?.score ?? 0, 0.98, accuracy: 0.001)
        XCTAssertTrue(outcome.alternatives.isEmpty)

        XCTAssertEqual(resolver.resolve("bell peper").hit?.ingredientID, 13)
        XCTAssertEqual(resolver.resolve("veggie brth").hit?.ingredientID, 1, "aliases count toward an entry's best score")
        XCTAssertEqual(resolver.resolve("chicken stok").hit?.ingredientID, 2)
    }

    func testFuzzyAlternativesFollowTheHit() {
        let outcome = resolver.resolve("chiken")
        XCTAssertEqual(outcome.hit?.ingredientID, 3, "Chicken (0.967) beats Chickpea (0.874)")
        XCTAssertEqual(outcome.alternatives.map(\.ingredientID), [10])
        XCTAssertEqual(outcome.alternatives.first?.via, .fuzzy)
        XCTAssertEqual(outcome.alternatives.first?.score ?? 0, 0.8736, accuracy: 0.001)
    }

    func testFuzzySuggestionsAreSortedCappedAndThresholded() {
        let suggestions = resolver.fuzzySuggestions(for: "chiken", limit: 3)
        XCTAssertEqual(suggestions.map(\.canonicalName), ["Chicken", "Chickpea"])
        XCTAssertEqual(suggestions.map(\.score), suggestions.map(\.score).sorted(by: >))
        XCTAssertEqual(resolver.fuzzySuggestions(for: "chiken", limit: 1).map(\.canonicalName), ["Chicken"])
        XCTAssertTrue(resolver.fuzzySuggestions(for: "chiken", limit: 0).isEmpty)
        XCTAssertTrue(resolver.fuzzySuggestions(for: "asdfqwer").isEmpty, "garbage proposes nothing")
        XCTAssertTrue(resolver.fuzzySuggestions(for: "   ").isEmpty)
        XCTAssertTrue(resolver.fuzzySuggestions(for: "(x)").isEmpty)
    }

    func testSubstringAndModifierTrapsDoNotResolve() {
        // Each trap is tested against an index that lacks the exact canonical, so the
        // query really reaches layer 2 — and must fall through to "new".
        let traps: [(query: String, index: IngredientIndex)] = [
            ("cream", IngredientIndex(entries: [Self.entry(4, "Sour cream", .dairy)])),
            ("chicken", IngredientIndex(entries: [Self.entry(2, "Chicken broth", .pantry)])),
            ("smoked paprika", IngredientIndex(entries: [Self.entry(6, "Paprika", .pantry)])),
            ("brown sugar", IngredientIndex(entries: [Self.entry(41, "Sugar", .pantry)])),
            ("garlic", IngredientIndex(entries: [Self.entry(12, "Garlic powder", .pantry)])),
        ]
        for trap in traps {
            let outcome = IngredientResolver(index: trap.index).resolve(trap.query)
            XCTAssertNil(outcome.hit, "\(trap.query) must not resolve onto \(trap.index.entries[0].canonicalName)")
            XCTAssertTrue(outcome.alternatives.isEmpty, trap.query)
        }
    }

    func testFuzzyThresholdIsTunable() {
        var strict = resolver
        strict.fuzzyThreshold = 0.99
        XCTAssertNil(strict.resolve("mozzarela").hit, "0.98 is below a 0.99 bar")
        var lax = resolver
        lax.fuzzyThreshold = 0.5
        XCTAssertEqual(lax.resolve("chicken broth soup").hit?.ingredientID, 2)
    }

    func testTwoExistingCanonicalsAreNeverMergedByFuzzy() {
        // "Smoked paprika" and "Paprika" both exist; the exact one wins and the other
        // is not even offered as an alternative (deterministic hit → no alternatives).
        let outcome = resolver.resolve("smoked paprika")
        XCTAssertEqual(outcome.hit, IngredientResolution(ingredientID: 7, resolution: .exact, score: 1))
        XCTAssertTrue(outcome.alternatives.isEmpty)
    }

    // MARK: - Layer 3

    private func semanticResolver(entries: [IngredientIndexEntry], vectors: [String: [Double]]) -> (resolver: IngredientResolver, embedding: FakeEmbedding) {
        let embedding = FakeEmbedding(vectors: vectors)
        let index = IngredientIndex(entries: entries)
        let resolver = IngredientResolver(index: index, embedding: embedding,
                                          semantic: SemanticCandidateSet.build(index: index, embedding: embedding))
        return (resolver, embedding)
    }

    func testSemanticNearMissBecomesAnEmbeddingHitWhenFuzzyIsSilent() {
        // "stock for soup" shares no useful token with any name (fuzzy is silent) but a
        // fake embedding places it next to Vegetable broth.
        let built = semanticResolver(entries: [Self.entry(1, "Vegetable broth", .pantry), Self.entry(3, "Chicken", .meat)],
                                     vectors: ["Vegetable broth": [0.99, 0.1], "Chicken": [0, 1], "stock for soup": [1, 0]])
        let outcome = built.resolver.resolve("stock for soup")
        XCTAssertEqual(outcome.hit?.ingredientID, 1)
        XCTAssertEqual(outcome.hit?.resolution, .embedding)
        XCTAssertEqual(outcome.hit?.score ?? 0, 0.995, accuracy: 0.001)
        XCTAssertTrue(outcome.alternatives.isEmpty, "Chicken is below the semantic threshold")
        XCTAssertTrue(built.embedding.requests.contains("stock for soup"), "the query was embedded")
    }

    func testSemanticLayerIsOffWithoutACandidateSet() {
        let plain = IngredientResolver(index: IngredientIndex(entries: [Self.entry(1, "Vegetable broth", .pantry)]))
        XCTAssertNil(plain.resolve("stock for soup").hit)
        XCTAssertNil(plain.semantic)

        // Not ready → build gives nil → layer 3 off, exactly the fuzzy behaviour.
        let notReady = FakeEmbedding(ready: false, vectors: ["stock for soup": [1, 0], "Vegetable broth": [1, 0]])
        let index = IngredientIndex(entries: [Self.entry(1, "Vegetable broth", .pantry)])
        let resolver = IngredientResolver(index: index, embedding: notReady,
                                          semantic: SemanticCandidateSet.build(index: index, embedding: notReady))
        XCTAssertNil(resolver.semantic)
        XCTAssertNil(resolver.resolve("stock for soup").hit)
    }

    func testSemanticCandidatesAreAdditiveAndNeverDisplaceAFuzzyHit() {
        // "sour creme" fuzzy-hits Sour cream at 0.907 — over the 0.86 threshold but
        // under the 0.93 escalation bar, so layer 3 is still consulted and its
        // (silly) near-miss is appended rather than substituted.
        let built = semanticResolver(entries: [Self.entry(4, "Sour cream", .dairy), Self.entry(1, "Vegetable broth", .pantry)],
                                     vectors: ["sour creme": [1, 0], "Vegetable broth": [0.99, 0.1], "Sour cream": [0, 1]])
        let outcome = built.resolver.resolve("sour creme")
        XCTAssertEqual(outcome.hit?.ingredientID, 4, "fuzzy hit is kept")
        XCTAssertEqual(outcome.hit?.resolution, .fuzzy)
        XCTAssertEqual(outcome.hit?.score ?? 0, 0.9067, accuracy: 0.001)
        XCTAssertEqual(outcome.alternatives.map(\.ingredientID), [1])
        XCTAssertEqual(outcome.alternatives.first?.via, .embedding)
    }

    /// The bar only means anything while it sits above the threshold — otherwise
    /// every fuzzy hit clears it and the additive path above is unreachable.
    func testTheEscalationBarSitsAboveTheFuzzyThreshold() {
        XCTAssertGreaterThan(IngredientResolver.defaultSemanticEscalationBar,
                             IngredientResolver.defaultFuzzyThreshold)
    }

    func testSemanticLayerIsNotConsultedWhenFuzzyIsConfident() {
        let built = semanticResolver(entries: [Self.entry(14, "Mozzarella", .dairy), Self.entry(1, "Vegetable broth", .pantry)],
                                     vectors: ["mozzarela": [1, 0], "Vegetable broth": [1, 0], "Mozzarella": [0, 1]])
        let outcome = built.resolver.resolve("mozzarela")
        XCTAssertEqual(outcome.hit?.resolution, .fuzzy)
        XCTAssertTrue(outcome.alternatives.isEmpty, "the cosine-1.0 broth was never even scored")
        XCTAssertFalse(built.embedding.requests.contains("mozzarela"), "0.98 ≥ the 0.85 bar: the query is not embedded")
    }

    func testSemanticThresholdIsTunable() {
        var built = semanticResolver(entries: [Self.entry(1, "Vegetable broth", .pantry)],
                                     vectors: ["Vegetable broth": [0.99, 0.1], "stock for soup": [1, 0]])
        XCTAssertNotNil(built.resolver.resolve("stock for soup").hit)
        built.resolver.semanticThreshold = 0.999
        XCTAssertNil(built.resolver.resolve("stock for soup").hit, "0.995 is below a 0.999 bar")
    }

    /// The spec starts these at the workout app's values and says to recalibrate on
    /// the corpus, expecting tighter (§13). It ended tighter:
    /// `docs/learnings/003-fuzzy-thresholds.md`.
    func testDefaultsMatchTheCalibratedValues() {
        XCTAssertEqual(IngredientResolver.defaultFuzzyThreshold, 0.86)
        XCTAssertEqual(IngredientResolver.defaultSemanticThreshold, 0.85)
        XCTAssertEqual(resolver.fuzzyThreshold, 0.86)
        XCTAssertEqual(resolver.semanticThreshold, 0.85)
        XCTAssertEqual(resolver.semanticEscalationBar, 0.93)
        XCTAssertFalse(resolver.embedding.isReady, "default embedding is the no-op")
    }

    // MARK: - resolveRow

    private func makeRow(_ line: String, guess: String? = nil, confidence: RowConfidence = .high, resolver: IngredientResolver? = nil) -> DraftRow {
        (resolver ?? self.resolver).resolveRow(IngredientLineSplitter.split(line), lineIndex: 3, canonicalGuess: guess, confidence: confidence)
    }

    func testRowCarriesTheLineAndTheHit() {
        let row = makeRow("2 cups veggie stock")
        XCTAssertEqual(row.lineIndex, 3)
        XCTAssertEqual(row.rawLine, "2 cups veggie stock")
        XCTAssertEqual(row.name, "veggie stock")
        XCTAssertEqual(row.quantity, 2)
        XCTAssertEqual(row.unitKey, "cup")
        XCTAssertEqual(row.unitText, "cups")
        XCTAssertNil(row.note)
        XCTAssertEqual(row.ingredient, .existing(1))
        XCTAssertEqual(row.ingredientName, "Vegetable broth")
        XCTAssertEqual(row.resolution, .alias)
        XCTAssertEqual(row.confidence, .high)
        XCTAssertNil(row.suggestion)
        XCTAssertTrue(row.alternatives.isEmpty)
        XCTAssertEqual(row.state, .resolved)
        XCTAssertFalse(row.blocksSave)
    }

    func testFuzzyRowIsHighlightedWithAlternatives() {
        let row = makeRow("1 lb chiken, cubed")
        XCTAssertEqual(row.name, "chiken")
        XCTAssertEqual(row.note, "cubed")
        XCTAssertEqual(row.ingredient, .existing(3))
        XCTAssertEqual(row.resolution, .fuzzy)
        XCTAssertEqual(row.alternatives.map(\.ingredientID), [10])
        XCTAssertEqual(row.state, .highlighted)
        XCTAssertFalse(row.blocksSave)
    }

    func testCanonicalGuessOnlyEverProducesASuggestion() {
        let row = makeRow("2 cups stock for soup", guess: "Vegetable broth", confidence: .medium)
        XCTAssertNil(row.ingredient, "the row is never resolved from the guess")
        XCTAssertNil(row.ingredientName)
        XCTAssertEqual(row.resolution, .none)
        XCTAssertEqual(row.suggestion?.ingredientID, 1)
        XCTAssertEqual(row.suggestion?.canonicalName, "Vegetable broth")
        XCTAssertEqual(row.suggestion?.via, .llm)
        XCTAssertEqual(row.suggestion?.score, 1)
        XCTAssertEqual(row.state, .suggested)
        XCTAssertTrue(row.blocksSave, "Use is a tap; the model never writes an alias")
    }

    func testCanonicalGuessRunsThroughAliasAndLooseLayers() {
        XCTAssertEqual(makeRow("stock for soup", guess: "veggie stock").suggestion?.ingredientID, 1, "alias")
        XCTAssertEqual(makeRow("stock for soup", guess: "chick peas").suggestion?.ingredientID, 10, "loose key")
        XCTAssertEqual(makeRow("stock for soup", guess: "  Chicken  ").suggestion?.ingredientID, 3, "trimmed exact")
    }

    func testUnresolvableGuessLeavesTheRowNew() {
        let row = makeRow("stock for soup", guess: "unicorn dust")
        XCTAssertNil(row.ingredient)
        XCTAssertNil(row.suggestion)
        XCTAssertEqual(row.resolution, .none)
        XCTAssertEqual(row.state, .new)
        XCTAssertTrue(row.blocksSave)
        XCTAssertNil(makeRow("stock for soup", guess: "   ").suggestion, "blank guess is no guess")
        XCTAssertNil(makeRow("stock for soup", guess: "mozzarela").suggestion, "layer 4 is deterministic only — no fuzzy on the guess")
    }

    func testAHitAlwaysWinsOverTheGuess() {
        let row = makeRow("2 cups veggie stock", guess: "Chicken")
        XCTAssertEqual(row.ingredient, .existing(1))
        XCTAssertNil(row.suggestion)
    }

    func testConfidenceOnlyAffectsHowTheRowIsShown() {
        let low = makeRow("2 cups veggie stock", confidence: .low)
        XCTAssertEqual(low.ingredient, .existing(1), "a low confidence never removes a deterministic hit")
        XCTAssertEqual(low.confidence, .low)
        XCTAssertEqual(low.state, .resolved)

        let medium = makeRow("2 cups veggie stock", confidence: .medium)
        XCTAssertEqual(medium.state, .highlighted)
    }

    func testUnresolvedLineStillGetsARowThatNeedsATap() {
        let row = makeRow("2 cups")
        XCTAssertEqual(row.name, "2 cups")
        XCTAssertEqual(row.quantity, 2)
        XCTAssertNil(row.ingredient)
        XCTAssertEqual(row.state, .new)
    }

    func testEmbeddingRowIsHighlighted() {
        let built = semanticResolver(entries: [Self.entry(1, "Vegetable broth", .pantry)],
                                     vectors: ["Vegetable broth": [0.99, 0.1], "stock for soup": [1, 0]])
        let row = makeRow("2 cups stock for soup", resolver: built.resolver)
        XCTAssertEqual(row.ingredient, .existing(1))
        XCTAssertEqual(row.resolution, .embedding)
        XCTAssertEqual(row.state, .highlighted)
    }
}
