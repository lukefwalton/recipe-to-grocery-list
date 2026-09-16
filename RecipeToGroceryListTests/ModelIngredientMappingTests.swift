import XCTest
@testable import RecipeToGroceryList

/// §7.3 "Mapping back", against hand-written model outputs (§11: skipped lines,
/// invented lines, invented quantities, junk confidence). No FoundationModels import
/// anywhere — this is the FM-free half of the adapter, and the half where the bugs
/// would live. Regex values asserted here were computed with the Python mirror of the
/// splitter first (`splitter_check.py` in the session scratchpad).
final class ModelIngredientMappingTests: XCTestCase {

    private func structured(_ lines: String...) -> [StructuredLine] {
        lines.map { IngredientLineSplitter.split($0) }
    }

    private func row(_ rawLine: String,
                     name: String,
                     guess: String = "",
                     quantity: Double? = nil,
                     unit: String? = nil,
                     note: String? = nil,
                     confidence: String = "high") -> RefinedRow {
        RefinedRow(rawLine: rawLine, name: name, canonicalGuess: guess,
                   quantity: quantity, unit: unit, note: note, confidence: confidence)
    }

    private func merge(_ regex: [StructuredLine], _ rows: [RefinedRow], warning: String? = nil) -> [ModelIngredientMapping.MergedLine] {
        ModelIngredientMapping.merge(regex: regex, model: RecipeRefinement(rows: rows, warning: warning))
    }

    // MARK: - Whole response

    func testNilResponseIsEveryLineRegex() {
        let regex = structured("2 cups flour", "salt to taste")
        let merged = ModelIngredientMapping.merge(regex: regex, model: nil)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.structured), regex)
        XCTAssertTrue(merged.allSatisfy { $0.canonicalGuess == nil })
        XCTAssertTrue(merged.allSatisfy { $0.confidence == .high })
        XCTAssertFalse(merged.contains(where: \.refinedByModel))
    }

    func testEmptyResponseIsEveryLineRegexToo() {
        let regex = structured("2 cups flour", "salt to taste")
        let merged = merge(regex, [])
        XCTAssertEqual(merged.map(\.structured), regex)
        XCTAssertFalse(merged.contains(where: \.refinedByModel))
    }

    func testEmptyInputMergesToNothingWhateverTheModelSays() {
        XCTAssertTrue(merge([], [row("1 tsp unicorn dust", name: "unicorn dust")]).isEmpty)
        XCTAssertTrue(ModelIngredientMapping.merge(regex: [], model: nil).isEmpty)
    }

    // MARK: - Lines: the model can never add or remove one

    func testSkippedLineFallsBackToRegex() {
        let regex = structured("2 cups flour", "salt to taste")
        let merged = merge(regex, [row("2 cups flour", name: "all-purpose flour", guess: "Flour")])
        XCTAssertEqual(merged.count, 2)

        XCTAssertTrue(merged[0].refinedByModel)
        XCTAssertEqual(merged[0].structured.name, "all-purpose flour")
        XCTAssertEqual(merged[0].canonicalGuess, "Flour")
        XCTAssertEqual(merged[0].structured.rawLine, "2 cups flour")

        XCTAssertFalse(merged[1].refinedByModel, "the skipped line is untouched")
        XCTAssertEqual(merged[1].structured, regex[1])
        XCTAssertNil(merged[1].canonicalGuess)
        XCTAssertEqual(merged[1].confidence, .high)
    }

    func testInventedLineIsIgnored() {
        let regex = structured("2 cups flour")
        let merged = merge(regex, [
            row("1 tsp unicorn dust", name: "unicorn dust", guess: "Unicorn dust", quantity: 1, unit: "tsp"),
        ])
        XCTAssertEqual(merged.count, 1, "one regex line in, one merged line out")
        XCTAssertEqual(merged[0].structured, regex[0])
        XCTAssertFalse(merged[0].refinedByModel)
        XCTAssertFalse(merged.contains { $0.structured.name == "unicorn dust" })
    }

    func testExtraRowsNeverChangeTheLineCount() {
        let regex = structured("2 cups flour", "salt")
        let merged = merge(regex, [
            row("2 cups flour", name: "flour", guess: "Flour"),
            row("salt", name: "salt", guess: "Salt"),
            row("1 lb butter", name: "butter", guess: "Butter"),
            row("2 eggs", name: "eggs", guess: "Egg"),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.structured.rawLine), ["2 cups flour", "salt"])
        XCTAssertTrue(merged.allSatisfy(\.refinedByModel))
    }

    func testMatchIsByTrimmedRawLine() {
        let regex = structured("2 cups flour")
        let merged = merge(regex, [row("  2 cups flour \n", name: "flour", guess: "Flour")])
        XCTAssertTrue(merged[0].refinedByModel)
        XCTAssertEqual(merged[0].canonicalGuess, "Flour")
        XCTAssertEqual(merged[0].structured.rawLine, "2 cups flour", "the regex line's raw text is what survives")
    }

    func testMatchIsCaseSensitiveLikeTheRawLine() {
        // "Unchanged" means unchanged; a re-cased line is not the input line.
        let merged = merge(structured("Salt to taste"), [row("salt to taste", name: "salt", guess: "Salt")])
        XCTAssertFalse(merged[0].refinedByModel)
    }

    func testDuplicateInputLinesShareOneModelRow() {
        let regex = structured("salt", "salt")
        let merged = merge(regex, [row("salt", name: "salt", guess: "Salt", confidence: "medium")])
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.allSatisfy(\.refinedByModel), "identical lines get identical treatment")
        XCTAssertEqual(merged.map(\.canonicalGuess), ["Salt", "Salt"])
        XCTAssertEqual(merged.map(\.confidence), [.medium, .medium])
    }

    func testFirstModelRowWinsForARepeatedRawLine() {
        let merged = merge(structured("salt"), [
            row("salt", name: "salt", guess: "Salt"),
            row("salt", name: "sea salt", guess: "Sea salt"),
        ])
        XCTAssertEqual(merged[0].structured.name, "salt")
        XCTAssertEqual(merged[0].canonicalGuess, "Salt")
    }

    // MARK: - Quantity: the model may not invent numbers

    func testInventedQuantityIsDropped() {
        let regex = structured("salt to taste")
        XCTAssertNil(regex[0].quantity, "precondition: the regex found no quantity")
        let merged = merge(regex, [row("salt to taste", name: "salt", guess: "Salt", quantity: 1)])
        XCTAssertTrue(merged[0].refinedByModel)
        XCTAssertNil(merged[0].structured.quantity, "regex nil → nil, whatever the model says")
        XCTAssertNil(merged[0].structured.quantityText)
    }

    func testModelQuantityIsAcceptedWhenTheRegexFoundOne() {
        let regex = structured("2 cups flour")
        XCTAssertEqual(regex[0].quantity, 2)
        let merged = merge(regex, [row("2 cups flour", name: "flour", guess: "Flour", quantity: 3)])
        XCTAssertEqual(merged[0].structured.quantity, 3)
        XCTAssertEqual(merged[0].structured.quantityText, "2", "the as-written text is not rewritten")
    }

    func testModelNilQuantityKeepsTheRegexValue() {
        let merged = merge(structured("1 1/2 cups flour"), [row("1 1/2 cups flour", name: "flour", guess: "Flour", quantity: nil)])
        XCTAssertEqual(merged[0].structured.quantity, 1.5)
    }

    func testNegativeNaNAndInfiniteQuantitiesKeepTheRegexValue() {
        for bad in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            let merged = merge(structured("2 cups flour"), [row("2 cups flour", name: "flour", guess: "Flour", quantity: bad)])
            XCTAssertEqual(merged[0].structured.quantity, 2, "\(bad) must not replace the regex value")
        }
    }

    func testZeroIsAnAcceptableModelQuantity() {
        let merged = merge(structured("2 cups flour"), [row("2 cups flour", name: "flour", guess: "Flour", quantity: 0)])
        XCTAssertEqual(merged[0].structured.quantity, 0, "≥ 0 is the rule; the validator accepts 0 too")
    }

    // MARK: - Confidence

    func testJunkConfidenceIsLow() {
        let regex = structured("2 cups flour")
        func confidence(_ raw: String) -> RowConfidence {
            merge(regex, [row("2 cups flour", name: "flour", confidence: raw)])[0].confidence
        }
        XCTAssertEqual(confidence("very sure"), .low)
        XCTAssertEqual(confidence(""), .low)
        XCTAssertEqual(confidence("0.9"), .low)
        XCTAssertEqual(confidence("low"), .low)
        XCTAssertEqual(confidence("HIGH"), .high)
        XCTAssertEqual(confidence(" Medium "), .medium)
        XCTAssertEqual(confidence("med"), .medium)
    }

    // MARK: - Unit

    func testKnownUnitSpellingResolvesToItsKey() {
        let regex = structured("2 cups flour")
        XCTAssertEqual(regex[0].unitKey, "cup")
        let merged = merge(regex, [row("2 cups flour", name: "flour", guess: "Flour", unit: " Tbsp. ")])
        XCTAssertEqual(merged[0].structured.unitKey, "tbsp")
        XCTAssertEqual(merged[0].structured.unitText, "Tbsp.", "the model's spelling, trimmed, is the display text")
    }

    func testCaseSensitiveSingleLetterUnitsAreRespected() {
        let regex = structured("2 cups flour")
        XCTAssertEqual(merge(regex, [row("2 cups flour", name: "flour", unit: "T")])[0].structured.unitKey, "tbsp")
        XCTAssertEqual(merge(regex, [row("2 cups flour", name: "flour", unit: "t")])[0].structured.unitKey, "tsp")
    }

    func testUnknownUnitKeepsTheRegexUnit() {
        let merged = merge(structured("2 cups flour"), [row("2 cups flour", name: "flour", guess: "Flour", unit: "smidgen")])
        XCTAssertEqual(merged[0].structured.unitKey, "cup")
        XCTAssertEqual(merged[0].structured.unitText, "cups")
    }

    func testBlankUnitKeepsTheRegexUnit() {
        let merged = merge(structured("2 cups flour"), [row("2 cups flour", name: "flour", unit: "   ")])
        XCTAssertEqual(merged[0].structured.unitKey, "cup")
        XCTAssertEqual(merged[0].structured.unitText, "cups")
    }

    func testKnownUnitIsAcceptedWhereTheRegexHadNone() {
        let regex = structured("1 onion, diced")
        XCTAssertNil(regex[0].unitKey)
        let merged = merge(regex, [row("1 onion, diced", name: "onion", guess: "Onion", unit: "whole")])
        XCTAssertEqual(merged[0].structured.unitKey, "piece", "a spelling the table knows is not an invention")
        XCTAssertEqual(merged[0].structured.unitText, "whole")
    }

    // MARK: - Name and note

    func testEmptyNameFallsBackToTheRegexName() {
        let merged = merge(structured("2 cups flour"), [row("2 cups flour", name: "   ", guess: "Flour")])
        XCTAssertEqual(merged[0].structured.name, "flour")
        XCTAssertTrue(merged[0].refinedByModel, "the row still counts as refined — its guess is used")
        XCTAssertEqual(merged[0].canonicalGuess, "Flour")
    }

    func testModelNameResolvesAnUnresolvedLine() {
        let regex = structured("2 cups")
        XCTAssertTrue(regex[0].isUnresolved, "precondition: §7.2 unresolved, name = raw line")
        XCTAssertEqual(regex[0].name, "2 cups")
        let merged = merge(regex, [row("2 cups", name: "flour", guess: "Flour")])
        XCTAssertEqual(merged[0].structured.name, "flour")
        XCTAssertFalse(merged[0].structured.isUnresolved)
        XCTAssertEqual(merged[0].structured.quantity, 2, "the regex quantity/unit survive alongside the model name")
        XCTAssertEqual(merged[0].structured.unitKey, "cup")
    }

    func testBlankModelNameLeavesAnUnresolvedLineUnresolved() {
        let merged = merge(structured("2 cups"), [row("2 cups", name: "", guess: "")])
        XCTAssertTrue(merged[0].structured.isUnresolved)
        XCTAssertEqual(merged[0].structured.name, "2 cups")
        XCTAssertNil(merged[0].canonicalGuess)
    }

    func testNoteIsTrimmedAndFallsBackToTheRegexNote() {
        let regex = structured("salt to taste")
        XCTAssertEqual(regex[0].note, "to taste")
        XCTAssertEqual(merge(regex, [row("salt to taste", name: "salt", note: "  sifted ")])[0].structured.note, "sifted")
        XCTAssertEqual(merge(regex, [row("salt to taste", name: "salt", note: "")])[0].structured.note, "to taste")
        XCTAssertEqual(merge(regex, [row("salt to taste", name: "salt", note: nil)])[0].structured.note, "to taste")
    }

    func testCanonicalGuessIsTrimmedAndNilWhenBlank() {
        let regex = structured("2 cups flour")
        XCTAssertEqual(merge(regex, [row("2 cups flour", name: "flour", guess: "  Flour ")])[0].canonicalGuess, "Flour")
        XCTAssertNil(merge(regex, [row("2 cups flour", name: "flour", guess: "   ")])[0].canonicalGuess)
        XCTAssertNil(merge(regex, [row("2 cups flour", name: "flour", guess: "")])[0].canonicalGuess)
    }

    func testAFullyRefinedRowCarriesEveryModelField() {
        let merged = merge(structured("2-3 tbsp olive oil, divided"), [
            row("2-3 tbsp olive oil, divided", name: "extra-virgin olive oil", guess: "Olive oil",
                quantity: 2.5, unit: "Tbsp", note: "divided", confidence: "high"),
        ])
        let line = merged[0].structured
        XCTAssertEqual(line.rawLine, "2-3 tbsp olive oil, divided")
        XCTAssertEqual(line.name, "extra-virgin olive oil")
        XCTAssertEqual(line.quantity, 2.5)
        XCTAssertEqual(line.quantityText, "2-3")
        XCTAssertEqual(line.unitKey, "tbsp")
        XCTAssertEqual(line.unitText, "Tbsp")
        XCTAssertEqual(line.note, "divided")
        XCTAssertFalse(line.isUnresolved)
        XCTAssertEqual(merged[0].canonicalGuess, "Olive oil")
        XCTAssertEqual(merged[0].confidence, .high)
        XCTAssertTrue(merged[0].refinedByModel)
    }

    // MARK: - Warning

    func testWarningIsTrimmedAndBlankBecomesNil() {
        XCTAssertEqual(ModelIngredientMapping.warning("  Two lines were not ingredients. \n"), "Two lines were not ingredients.")
        XCTAssertNil(ModelIngredientMapping.warning("   "))
        XCTAssertNil(ModelIngredientMapping.warning(""))
        XCTAssertNil(ModelIngredientMapping.warning(nil))
    }

    func testMergedLineDefaultsAreTheRegexPosture() {
        let line = ModelIngredientMapping.MergedLine(structured: IngredientLineSplitter.split("salt"))
        XCTAssertNil(line.canonicalGuess)
        XCTAssertEqual(line.confidence, .high)
        XCTAssertFalse(line.refinedByModel)
    }
}
