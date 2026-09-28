import XCTest
@testable import RecipeToGroceryList

/// §7 end to end on a hand-built index, with the model driven by `FakeRefiner`: line
/// indices around headers, the two decline reasons, the AI / no-AI / declined-AI
/// copy, and layer 4 producing a *suggestion* and nothing more. No FoundationModels,
/// NaturalLanguage or store involved — the resolver runs on `NoopEmbedding`.
final class RecipePipelineTests: XCTestCase {

    private static func entry(_ id: Int64, _ name: String, _ category: IngredientCategory, _ aliases: [String] = []) -> IngredientIndexEntry {
        IngredientIndexEntry(id: id, canonicalName: name, category: category,
                             aliases: aliases.map(IngredientNormalizer.normalize))
    }

    /// Four canonicals. "stock for soup", "salt" and "flour" fuzzy-score below 0.78
    /// — and so, a fortiori, below the calibrated 0.86 threshold —
    /// against every name and alias here (checked with the Python port of the metric),
    /// so they reach layer 4 / land in *New* deterministically.
    private let index = IngredientIndex(entries: [
        RecipePipelineTests.entry(1, "Vegetable broth", .pantry, ["veggie broth", "vegetable stock"]),
        RecipePipelineTests.entry(2, "Garlic", .produce),
        RecipePipelineTests.entry(3, "Onion", .produce),
        RecipePipelineTests.entry(4, "Olive oil", .pantry),
    ])

    private let source = RecipeSource(kind: .text, titleGuess: "Lentil soup")

    private static let soupText = """
    For the soup:
    - 2 cups vegetable stock
    3 cloves garlic
    Garnish:
    1 onion, diced
    """

    private func pipeline(_ refiner: RecipeRefining?) -> RecipePipeline {
        RecipePipeline(resolver: IngredientResolver(index: index, embedding: NoopEmbedding()), refiner: refiner)
    }

    private func parsed(_ outcome: RecipeParseOutcome, file: StaticString = #filePath, line: UInt = #line) -> ParsedRecipe? {
        guard case .draft(let recipe) = outcome else {
            XCTFail("expected a draft, got \(outcome)", file: file, line: line)
            return nil
        }
        return recipe
    }

    // MARK: - Lines and indices

    func testHeadersStayInRawLinesAndRowsCarryTheirLineIndex() async {
        guard let result = parsed(await pipeline(nil).run(text: Self.soupText, source: source)) else { return }
        let draft = result.draft

        XCTAssertEqual(draft.rawLines, ["For the soup:", "2 cups vegetable stock", "3 cloves garlic", "Garnish:", "1 onion, diced"],
                       "every cleaned line survives, headers included, bullets stripped")
        XCTAssertEqual(draft.rows.count, 3, "one row per ingredient line, never per header")
        XCTAssertEqual(draft.rows.map(\.lineIndex), [1, 2, 4], "indices are into rawLines — headers occupy indices too")
        XCTAssertEqual(draft.headerLineIndices, [0, 3])
        XCTAssertEqual(draft.rows.map(\.rawLine), ["2 cups vegetable stock", "3 cloves garlic", "1 onion, diced"])
        for row in draft.rows {
            XCTAssertEqual(draft.rawLines[row.lineIndex], row.rawLine)
        }

        XCTAssertEqual(draft.rows[0].name, "vegetable stock")
        XCTAssertEqual(draft.rows[0].quantity, 2)
        XCTAssertEqual(draft.rows[0].unitKey, "cup")
        XCTAssertEqual(draft.rows[0].ingredient, .existing(1))
        XCTAssertEqual(draft.rows[0].ingredientName, "Vegetable broth")
        XCTAssertEqual(draft.rows[0].resolution, .alias)

        XCTAssertEqual(draft.rows[1].ingredient, .existing(2))
        XCTAssertEqual(draft.rows[1].resolution, .exact)
        XCTAssertEqual(draft.rows[1].unitKey, "clove")

        XCTAssertEqual(draft.rows[2].ingredient, .existing(3))
        XCTAssertEqual(draft.rows[2].note, "diced")

        XCTAssertEqual(draft.title, "Lentil soup")
        XCTAssertEqual(draft.source, source)
        XCTAssertTrue(draft.newIngredients.isEmpty)
        XCTAssertTrue(draft.newAliases.isEmpty)
        XCTAssertTrue(draft.canSave, "all three rows resolved deterministically")
    }

    func testRunLinesAndRunTextAgree() async {
        let fromText = parsed(await pipeline(nil).run(text: Self.soupText, source: source))
        let fromLines = parsed(await pipeline(nil).run(lines: Self.soupText.components(separatedBy: "\n"), source: source))
        guard let a = fromText, let b = fromLines else { return }
        // Row ids are fresh UUIDs, so compare the projections that matter.
        XCTAssertEqual(a.draft.rawLines, b.draft.rawLines)
        XCTAssertEqual(a.draft.rows.map(\.lineIndex), b.draft.rows.map(\.lineIndex))
        XCTAssertEqual(a.draft.rows.map(\.name), b.draft.rows.map(\.name))
        XCTAssertEqual(a.draft.rows.map(\.ingredient), b.draft.rows.map(\.ingredient))
        XCTAssertEqual(a.usedOnDeviceAI, b.usedOnDeviceAI)
        XCTAssertEqual(a.warning, b.warning)
    }

    // MARK: - Declines

    func testEmptyInputDeclinesWithNoLines() async {
        // `await` cannot sit inside XCTAssertEqual's autoclosure, so each outcome is hoisted.
        let sut = pipeline(FakeRefiner(RecipeRefinement(rows: [])))
        let empty = await sut.run(text: "", source: source)
        XCTAssertEqual(empty, .declined(.noLines))
        let whitespace = await sut.run(text: "  \n\n\t\n", source: source)
        XCTAssertEqual(whitespace, .declined(.noLines))
        let decoration = await sut.run(text: "-\n•\n", source: source)
        XCTAssertEqual(decoration, .declined(.noLines), "decoration-only lines are empty lines")
        let noLines = await sut.run(lines: [], source: source)
        XCTAssertEqual(noLines, .declined(.noLines))
        let blankLines = await sut.run(lines: ["", "   "], source: source)
        XCTAssertEqual(blankLines, .declined(.noLines))
        let noCleaned = await sut.run(cleaned: [], source: source)
        XCTAssertEqual(noCleaned, .declined(.noLines))
    }

    func testOnlyHeadersDeclinesWithNoIngredientLines() async {
        let sut = pipeline(FakeRefiner(RecipeRefinement(rows: [])))
        let headersOnly = await sut.run(text: "For the sauce:\nToppings:", source: source)
        XCTAssertEqual(headersOnly, .declined(.noIngredientLines))
        let oneHeader = await sut.run(cleaned: [.sectionHeader("Sauce:")], source: source)
        XCTAssertEqual(oneHeader, .declined(.noIngredientLines))
    }

    func testDeclinesNeverReachTheRefiner() async {
        let fake = FakeRefiner(RecipeRefinement(rows: []))
        _ = await pipeline(fake).run(text: "", source: source)
        _ = await pipeline(fake).run(text: "Sauce:", source: source)
        XCTAssertEqual(fake.callCount, 0, "no request for nothing")
    }

    func testDeclineReasonsHaveCopy() {
        XCTAssertFalse(RecipeDeclineReason.noLines.message.isEmpty)
        XCTAssertFalse(RecipeDeclineReason.noIngredientLines.message.isEmpty)
        XCTAssertNotEqual(RecipeDeclineReason.noLines.message, RecipeDeclineReason.noIngredientLines.message)
    }

    // MARK: - With and without the model

    func testNoRefinerMeansNoAIAndNoWarning() async {
        guard let result = parsed(await pipeline(nil).run(text: Self.soupText, source: source)) else { return }
        XCTAssertFalse(result.usedOnDeviceAI)
        XCTAssertNil(result.warning, "the 'unavailable' copy is Confirm's to show; the pipeline has nothing to warn about")
    }

    func testRefinerDecliningFallsBackToRegexWithTheParsedWithoutAICopy() async {
        let fake = FakeRefiner(nil)
        guard let result = parsed(await pipeline(fake).run(text: Self.soupText, source: source)) else { return }
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertFalse(result.usedOnDeviceAI)
        XCTAssertEqual(result.warning, RecipeParserFactory.parsedWithoutAICopy)
        XCTAssertEqual(result.draft.rows.count, 3, "every line still gets its regex row")
        XCTAssertEqual(result.draft.rows.map(\.ingredient), [.existing(1), .existing(2), .existing(3)])
        XCTAssertTrue(result.draft.rows.allSatisfy { $0.confidence == .high })
    }

    func testRefinerAnsweringSetsUsedOnDeviceAIAndSurfacesItsWarning() async {
        let fake = FakeRefiner(RecipeRefinement(rows: [], warning: "  Two lines were not ingredients. "))
        guard let result = parsed(await pipeline(fake).run(text: Self.soupText, source: source)) else { return }
        XCTAssertTrue(result.usedOnDeviceAI, "an answer with no usable rows is still an answer")
        XCTAssertEqual(result.warning, "Two lines were not ingredients.")
        XCTAssertEqual(result.draft.rows.map(\.ingredient), [.existing(1), .existing(2), .existing(3)], "no rows matched → regex everywhere")
    }

    func testRefinerAnsweringWithABlankWarningHasNoWarning() async {
        let fake = FakeRefiner(RecipeRefinement(rows: [], warning: "   "))
        guard let result = parsed(await pipeline(fake).run(text: Self.soupText, source: source)) else { return }
        XCTAssertTrue(result.usedOnDeviceAI)
        XCTAssertNil(result.warning)
    }

    func testRefinerReceivesOnlyIngredientLinesAndTheIndexCanonicalNames() async {
        let fake = FakeRefiner(nil)
        _ = await pipeline(fake).run(text: Self.soupText, source: source)
        XCTAssertEqual(fake.calls.count, 1, "one request per recipe, not per line")
        XCTAssertEqual(fake.calls.first?.lines, ["2 cups vegetable stock", "3 cloves garlic", "1 onion, diced"],
                       "headers are not sent; bullets are already stripped")
        XCTAssertEqual(fake.calls.first?.knownIngredients, index.canonicalNames)
        XCTAssertEqual(fake.calls.first?.knownIngredients, ["Garlic", "Olive oil", "Onion", "Vegetable broth"])
    }

    // MARK: - Layer 4: the guess is only ever a suggestion

    func testGuessThatHitsBecomesAnLLMSuggestionNotAResolution() async {
        let fake = FakeRefiner(RecipeRefinement(rows: [
            RefinedRow(rawLine: "2 cups stock for soup", name: "stock for soup", canonicalGuess: "veggie broth",
                       quantity: 2, unit: "cups", note: nil, confidence: "medium"),
        ]))
        guard let result = parsed(await pipeline(fake).run(text: "2 cups stock for soup\nsalt", source: source)) else { return }
        XCTAssertTrue(result.usedOnDeviceAI)
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.draft.rows.count, 2)

        let suggested = result.draft.rows[0]
        XCTAssertEqual(suggested.name, "stock for soup")
        XCTAssertNil(suggested.ingredient, "the row is never resolved from the guess")
        XCTAssertNil(suggested.ingredientName)
        XCTAssertEqual(suggested.resolution, .none)
        XCTAssertEqual(suggested.confidence, .medium)
        XCTAssertEqual(suggested.suggestion?.ingredientID, 1, "the guess ran through the alias layer")
        XCTAssertEqual(suggested.suggestion?.canonicalName, "Vegetable broth")
        XCTAssertEqual(suggested.suggestion?.via, .llm)
        XCTAssertEqual(suggested.state, .suggested)
        XCTAssertTrue(suggested.blocksSave, "Use is a tap; the model never writes an alias")

        let untouched = result.draft.rows[1]
        XCTAssertEqual(untouched.name, "salt")
        XCTAssertNil(untouched.suggestion)
        XCTAssertEqual(untouched.confidence, .high, "a line the model skipped keeps the regex posture")
        XCTAssertEqual(untouched.state, .new)

        XCTAssertFalse(result.draft.canSave)
    }

    func testGuessThatMissesLeavesTheRowNew() async {
        let fake = FakeRefiner(RecipeRefinement(rows: [
            RefinedRow(rawLine: "2 cups stock for soup", name: "stock for soup", canonicalGuess: "unicorn dust", confidence: "medium"),
        ]))
        guard let result = parsed(await pipeline(fake).run(text: "2 cups stock for soup", source: source)) else { return }
        let row = result.draft.rows[0]
        XCTAssertNil(row.ingredient)
        XCTAssertNil(row.suggestion, "§13: a guess outside the set lands in New like any other row")
        XCTAssertEqual(row.resolution, .none)
        XCTAssertEqual(row.state, .new)
        XCTAssertTrue(row.blocksSave)
    }

    func testDeterministicHitIsUnaffectedByAWrongGuess() async {
        let fake = FakeRefiner(RecipeRefinement(rows: [
            RefinedRow(rawLine: "3 cloves garlic", name: "garlic", canonicalGuess: "Onion", quantity: 3, unit: "cloves", confidence: "low"),
        ]))
        guard let result = parsed(await pipeline(fake).run(text: "3 cloves garlic", source: source)) else { return }
        let row = result.draft.rows[0]
        XCTAssertEqual(row.ingredient, .existing(2), "layer 0 hit; the guess is never consulted")
        XCTAssertEqual(row.ingredientName, "Garlic")
        XCTAssertEqual(row.resolution, .exact)
        XCTAssertNil(row.suggestion)
        XCTAssertEqual(row.confidence, .low)
        XCTAssertEqual(row.state, .highlighted, "low confidence never removes a deterministic hit — it flags it")
        XCTAssertFalse(row.blocksSave)
    }

    func testMediumConfidenceHighlightsAResolvedRow() async {
        let fake = FakeRefiner(RecipeRefinement(rows: [
            RefinedRow(rawLine: "3 cloves garlic", name: "garlic", canonicalGuess: "Garlic", confidence: "medium"),
        ]))
        guard let result = parsed(await pipeline(fake).run(text: "3 cloves garlic", source: source)) else { return }
        XCTAssertEqual(result.draft.rows[0].ingredient, .existing(2))
        XCTAssertEqual(result.draft.rows[0].state, .highlighted)
        XCTAssertTrue(result.draft.canSave, "highlighted rows are accepted by Save")
    }

    // MARK: - Refined fields reach the row

    func testRefinedQuantityUnitNoteAndNameFlowIntoTheRow() async {
        let fake = FakeRefiner(RecipeRefinement(rows: [
            RefinedRow(rawLine: "2 cups olive oil", name: "extra-virgin olive oil", canonicalGuess: "Olive oil",
                       quantity: 3, unit: "Tbsp", note: "for frying", confidence: "high"),
        ]))
        guard let result = parsed(await pipeline(fake).run(text: "2 cups olive oil", source: source)) else { return }
        let row = result.draft.rows[0]
        XCTAssertEqual(row.rawLine, "2 cups olive oil", "raw line is never edited")
        XCTAssertEqual(row.name, "extra-virgin olive oil")
        XCTAssertEqual(row.quantity, 3)
        XCTAssertEqual(row.unitKey, "tbsp")
        XCTAssertEqual(row.unitText, "Tbsp")
        XCTAssertEqual(row.note, "for frying")
        // The model's name misses the deterministic layers and fuzzy ("extra-virgin olive
        // oil" vs "Olive oil": different word counts, symmetric token score), so the guess
        // becomes the suggestion — exactly the §7.4 layer-4 path.
        XCTAssertNil(row.ingredient)
        XCTAssertEqual(row.suggestion?.ingredientID, 4)
        XCTAssertEqual(row.suggestion?.via, .llm)
        XCTAssertEqual(row.state, .suggested)
    }

    func testModelCannotInventAQuantityOrALineThroughThePipeline() async {
        let fake = FakeRefiner(RecipeRefinement(rows: [
            RefinedRow(rawLine: "salt", name: "salt", canonicalGuess: "Salt", quantity: 1, unit: "tsp", confidence: "high"),
            RefinedRow(rawLine: "1 lb unicorn", name: "unicorn", canonicalGuess: "Unicorn", quantity: 1, unit: "lb", confidence: "high"),
        ]))
        guard let result = parsed(await pipeline(fake).run(text: "salt", source: source)) else { return }
        XCTAssertEqual(result.draft.rows.count, 1)
        XCTAssertEqual(result.draft.rawLines, ["salt"])
        XCTAssertNil(result.draft.rows[0].quantity, "regex found none → the model's 1 is dropped")
        XCTAssertEqual(result.draft.rows[0].unitKey, "tsp", "a known unit spelling is accepted on its own")
        XCTAssertFalse(result.draft.rows.contains { $0.rawLine == "1 lb unicorn" })
    }

    // MARK: - Title

    func testTitleComesFromTheSourceGuessTrimmedOrIsEmpty() async {
        let padded = RecipeSource(kind: .url, ref: "https://example.com/soup", titleGuess: "  Lentil soup \n", servingsText: "4")
        guard let a = parsed(await pipeline(nil).run(text: "salt", source: padded)) else { return }
        XCTAssertEqual(a.draft.title, "Lentil soup")
        XCTAssertEqual(a.draft.source, padded, "the source is passed through untouched")

        guard let b = parsed(await pipeline(nil).run(text: "3 cloves garlic", source: RecipeSource(kind: .photo))) else { return }
        XCTAssertEqual(b.draft.title, "", "no guess → Confirm asks")
        XCTAssertFalse(b.draft.canSave, "a resolved row but no title")

        guard let c = parsed(await pipeline(nil).run(text: "3 cloves garlic", source: RecipeSource(kind: .text, titleGuess: "   "))) else { return }
        XCTAssertEqual(c.draft.title, "")

        XCTAssertEqual(RecipePipeline.title(from: RecipeSource(kind: .text, titleGuess: " x ")), "x")
        XCTAssertEqual(RecipePipeline.title(from: RecipeSource(kind: .text)), "")
    }

    // MARK: - Factory

    func testFactoryCopyMatchesTheSpec() {
        XCTAssertEqual(RecipeParserFactory.parsedWithoutAICopy, "Parsed without on-device AI.")
        XCTAssertEqual(RecipeParserFactory.unavailableCopy,
                       "On-device AI isn't available on this device; a few more rows may need a tap.")
    }

    func testFactoryRefinerAndAvailabilityAgree() {
        // True in both compile branches: no SDK → nil/false; SDK on a simulator → the
        // runtime check fails → nil/false; a real FM device → refiner/true.
        XCTAssertEqual(RecipeParserFactory.makeRefiner() != nil, RecipeParserFactory.onDeviceAIAvailable)
    }

    // MARK: - Fake

    func testFakeRefinerPlaysItsSequenceThenRepeatsTheLast() async {
        let first = RecipeRefinement(rows: [], warning: "first")
        let fake = FakeRefiner(sequence: [nil, first])
        let a = await fake.refine(lines: ["x"], knownIngredients: [])
        let b = await fake.refine(lines: ["y"], knownIngredients: ["Salt"])
        let c = await fake.refine(lines: ["z"], knownIngredients: [])
        XCTAssertNil(a)
        XCTAssertEqual(b, first)
        XCTAssertEqual(c, first)
        XCTAssertEqual(fake.callCount, 3)
        XCTAssertEqual(fake.calls[1], FakeRefiner.Call(lines: ["y"], knownIngredients: ["Salt"]))
    }
}
