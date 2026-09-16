import XCTest
@testable import RecipeToGroceryList

/// Every refusal the write gate can make (spec §7.5 "Save is disabled until…" and
/// the store contract). Each test builds a draft that is valid except for the one
/// thing under test, so the error asserted is the only reason it fails.
final class RecipeValidatorTests: XCTestCase {

    // MARK: - Builders

    private func row(_ rawLine: String,
                     name: String? = nil,
                     ingredient: IngredientRef? = .existing(1),
                     resolution: RowResolution = .exact,
                     quantity: Double? = nil,
                     unitKey: String? = nil,
                     keepAsText: Bool = false,
                     isRemoved: Bool = false,
                     suggestion: IngredientSuggestion? = nil) -> DraftRow {
        DraftRow(lineIndex: 0,
                 rawLine: rawLine,
                 name: name ?? rawLine,
                 quantity: quantity,
                 unitKey: unitKey,
                 ingredient: ingredient,
                 resolution: resolution,
                 suggestion: suggestion,
                 keepAsText: keepAsText,
                 isRemoved: isRemoved)
    }

    private func draft(title: String = "Lentil soup",
                       rawLines: [String]? = nil,
                       rows: [DraftRow],
                       newIngredients: [PendingIngredient] = [],
                       newAliases: [PendingAlias] = []) -> RecipeDraft {
        RecipeDraft(title: title,
                    source: RecipeSource(kind: .text),
                    rawLines: rawLines ?? rows.map(\.rawLine),
                    rows: rows,
                    newIngredients: newIngredients,
                    newAliases: newAliases)
    }

    private func assertRefused(_ draft: RecipeDraft, with expected: RecipeValidationError,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RecipeValidator.validate(draft), file: file, line: line) { error in
            XCTAssertEqual(error as? RecipeValidationError, expected, file: file, line: line)
        }
    }

    // MARK: - Draft-level

    func testValidDraftPasses() throws {
        let pending = PendingIngredient(name: "Za'atar", category: .pantry)
        let valid = draft(rawLines: ["For the soup:", "2 cloves garlic", "1 tbsp za'atar", "a splash of something", "Salt"], rows: [
            row("2 cloves garlic", name: "garlic", quantity: 2, unitKey: "clove"),
            row("1 tbsp za'atar", name: "za'atar", ingredient: .pending(pending.id), resolution: .user, quantity: 1, unitKey: "tbsp"),
            row("a splash of something", ingredient: nil, resolution: .none, keepAsText: true),
            row("Salt", ingredient: nil, resolution: .none, isRemoved: true),
        ], newIngredients: [pending], newAliases: [
            PendingAlias(alias: "zaatar spice", target: .pending(pending.id)),
            PendingAlias(alias: "garlic cloves", target: .existing(1)),
        ])
        XCTAssertNoThrow(try RecipeValidator.validate(valid))
        XCTAssertTrue(valid.canSave, "the UI gate and the validator agree")
    }

    func testEmptyTitle() {
        assertRefused(draft(title: "   ", rows: [row("garlic")]), with: .emptyTitle)
    }

    func testNoRawLines() {
        assertRefused(draft(rawLines: [], rows: [row("garlic")]), with: .noRawLines)
    }

    func testNoRows() {
        assertRefused(draft(rawLines: ["For the soup:"], rows: []), with: .noRows)
        assertRefused(draft(rows: [row("garlic", isRemoved: true)]), with: .noRows)
    }

    // MARK: - Row-level

    func testRowStillNeedsDecisionForNewAndSuggestedRows() {
        assertRefused(draft(rows: [row("mystery powder", ingredient: nil, resolution: .none)]),
                      with: .rowStillNeedsDecision(line: "mystery powder"))
        let suggestion = IngredientSuggestion(ingredientID: 1, canonicalName: "Vegetable broth", score: 1, via: .llm)
        assertRefused(draft(rows: [row("veggie stock", ingredient: nil, resolution: .none, suggestion: suggestion)]),
                      with: .rowStillNeedsDecision(line: "veggie stock"))
    }

    func testRowEmptyName() {
        assertRefused(draft(rows: [row("2 cloves garlic", name: "   ")]), with: .rowEmptyName(line: "2 cloves garlic"))
    }

    func testRowBadQuantity() {
        assertRefused(draft(rows: [row("-1 onion", quantity: -1)]), with: .rowBadQuantity(line: "-1 onion"))
        assertRefused(draft(rows: [row("nan onion", quantity: .nan)]), with: .rowBadQuantity(line: "nan onion"))
        assertRefused(draft(rows: [row("inf onion", quantity: .infinity)]), with: .rowBadQuantity(line: "inf onion"))
        XCTAssertNoThrow(try RecipeValidator.validate(draft(rows: [row("0 onion", quantity: 0)])), "zero is legal")
        XCTAssertNoThrow(try RecipeValidator.validate(draft(rows: [row("onion")])), "nil is legal")
    }

    func testRowUnknownUnit() {
        assertRefused(draft(rows: [row("1 smidgen salt", quantity: 1, unitKey: "smidgen")]),
                      with: .rowUnknownUnit(line: "1 smidgen salt"))
        XCTAssertNoThrow(try RecipeValidator.validate(draft(rows: [row("1 tbsp salt", quantity: 1, unitKey: "tbsp")])))
    }

    func testRowInconsistentWhenKeptAsTextButHasAnIngredient() {
        assertRefused(draft(rows: [row("garlic", ingredient: .existing(1), resolution: .exact, keepAsText: true)]),
                      with: .rowInconsistent(line: "garlic"))
    }

    func testRowInconsistentWhenKeptAsTextButResolutionIsNotNone() {
        assertRefused(draft(rows: [row("garlic", ingredient: nil, resolution: .exact, keepAsText: true)]),
                      with: .rowInconsistent(line: "garlic"))
    }

    func testRowInconsistentWhenIngredientHasNoResolution() {
        assertRefused(draft(rows: [row("garlic", ingredient: .existing(1), resolution: .none)]),
                      with: .rowInconsistent(line: "garlic"))
    }

    func testDanglingPendingReference() {
        assertRefused(draft(rows: [row("za'atar", ingredient: .pending(UUID()), resolution: .user)]),
                      with: .danglingPendingReference(line: "za'atar"))
    }

    func testRemovedRowsAreNotValidated() {
        // A removed line is kept in raw_lines only; whatever the parser made of it
        // must not block the save.
        let removed = row("???", name: "", ingredient: nil, resolution: .none, quantity: -5, unitKey: "smidgen", isRemoved: true)
        XCTAssertNoThrow(try RecipeValidator.validate(draft(rows: [row("garlic"), removed])))
    }

    // MARK: - Pending ingredients & aliases

    func testPendingIngredientEmptyName() {
        let blank = PendingIngredient(name: "   ", category: .other)
        assertRefused(draft(rows: [row("x", ingredient: .pending(blank.id), resolution: .user)], newIngredients: [blank]),
                      with: .pendingIngredientEmptyName)
        // Only a parenthetical: non-blank as typed, but normalizes to nothing.
        let parenthetical = PendingIngredient(name: "(optional)", category: .other)
        assertRefused(draft(rows: [row("x", ingredient: .pending(parenthetical.id), resolution: .user)], newIngredients: [parenthetical]),
                      with: .pendingIngredientEmptyName)
    }

    func testDuplicatePendingIngredientUnderNormalization() {
        let first = PendingIngredient(name: "Tomatoes", category: .produce)
        let second = PendingIngredient(name: "tomato", category: .produce)
        assertRefused(draft(rows: [row("tomatoes", ingredient: .pending(first.id), resolution: .user)],
                            newIngredients: [first, second]),
                      with: .duplicatePendingIngredient("tomato"))
    }

    func testEmptyAlias() {
        assertRefused(draft(rows: [row("garlic")], newAliases: [PendingAlias(alias: "   ", target: .existing(1))]),
                      with: .emptyAlias)
        assertRefused(draft(rows: [row("garlic")], newAliases: [PendingAlias(alias: "(see note)", target: .existing(1))]),
                      with: .emptyAlias)
    }

    func testDanglingAliasTarget() {
        assertRefused(draft(rows: [row("garlic")], newAliases: [PendingAlias(alias: "garlic clove", target: .pending(UUID()))]),
                      with: .danglingAliasTarget)
    }
}
