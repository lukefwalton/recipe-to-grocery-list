import XCTest
@testable import RecipeToGroceryList

/// §7.2 quantity grammar, one element per test. Expected values were checked with
/// the Python design prototype (`splitter_check.py`) before being asserted.
final class QuantityParserTests: XCTestCase {

    private func parse(_ text: String) -> (quantity: ParsedQuantity, remainder: String)? {
        QuantityParser.parse(leading: text)
    }

    private func assertQuantity(_ text: String, value: Double, quantityText: String, rangeText: String? = nil,
                                remainder: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let result = parse(text) else {
            XCTFail("expected a quantity at the start of \(text.debugDescription)", file: file, line: line)
            return
        }
        XCTAssertEqual(result.quantity.value, value, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(result.quantity.text, quantityText, file: file, line: line)
        XCTAssertEqual(result.quantity.rangeText, rangeText, file: file, line: line)
        XCTAssertEqual(result.remainder, remainder, file: file, line: line)
    }

    // MARK: - Numbers

    func testIntegersAndDecimals() {
        assertQuantity("2 cups", value: 2, quantityText: "2", remainder: "cups")
        assertQuantity("1.5 cups", value: 1.5, quantityText: "1.5", remainder: "cups")
        assertQuantity(".5 cup", value: 0.5, quantityText: ".5", remainder: "cup")
        assertQuantity("500 g flour", value: 500, quantityText: "500", remainder: "g flour")
    }

    func testASCIIFractionsAndMixedNumbers() {
        assertQuantity("1/2 cup", value: 0.5, quantityText: "1/2", remainder: "cup")
        assertQuantity("3/4 tsp", value: 0.75, quantityText: "3/4", remainder: "tsp")
        assertQuantity("1 1/2 tsp. kosher salt", value: 1.5, quantityText: "1 1/2", remainder: "tsp. kosher salt")
        assertQuantity("1-1/2 cups milk", value: 1.5, quantityText: "1-1/2", remainder: "cups milk")
        assertQuantity("2 1/2 cups", value: 2.5, quantityText: "2 1/2", remainder: "cups")
        assertQuantity("1⁄2 cup", value: 0.5, quantityText: "1⁄2", remainder: "cup")
    }

    func testVulgarFractions() {
        assertQuantity("½ cup heavy cream", value: 0.5, quantityText: "½", remainder: "cup heavy cream")
        assertQuantity("⅓ cup", value: 1.0 / 3.0, quantityText: "⅓", remainder: "cup")
        assertQuantity("1½ cups milk", value: 1.5, quantityText: "1½", remainder: "cups milk")
        assertQuantity("1 ½ cups milk", value: 1.5, quantityText: "1 ½", remainder: "cups milk")
        assertQuantity("2¾ lb", value: 2.75, quantityText: "2¾", remainder: "lb")
        XCTAssertEqual(QuantityParser.value(ofVulgarFraction: "½"), 0.5)
        XCTAssertEqual(QuantityParser.value(ofVulgarFraction: "⅞"), 0.875)
        XCTAssertNil(QuantityParser.value(ofVulgarFraction: "x"))
        XCTAssertNil(QuantityParser.value(ofVulgarFraction: "1"))
    }

    func testRangesUseTheLowerBoundAndKeepTheText() {
        assertQuantity("2-3 lemons", value: 2, quantityText: "2-3", rangeText: "2-3", remainder: "lemons")
        assertQuantity("2–3 tablespoons olive oil", value: 2, quantityText: "2–3", rangeText: "2–3", remainder: "tablespoons olive oil")
        assertQuantity("2—3 tbsp", value: 2, quantityText: "2—3", rangeText: "2—3", remainder: "tbsp")
        assertQuantity("2 - 3 lemons", value: 2, quantityText: "2 - 3", rangeText: "2 - 3", remainder: "lemons")
        assertQuantity("2 to 3 cups spinach", value: 2, quantityText: "2 to 3", rangeText: "2 to 3", remainder: "cups spinach")
        assertQuantity("2 or 3 eggs", value: 2, quantityText: "2 or 3", rangeText: "2 or 3", remainder: "eggs")
        assertQuantity("6-8 cups water", value: 6, quantityText: "6-8", rangeText: "6-8", remainder: "cups water")
        assertQuantity("1 1/2 - 2 cups", value: 1.5, quantityText: "1 1/2 - 2", rangeText: "1 1/2 - 2", remainder: "cups")
        assertQuantity("½-1 tsp", value: 0.5, quantityText: "½-1", rangeText: "½-1", remainder: "tsp")
    }

    func testGluedUnitsAreABoundary() {
        assertQuantity("500ml chicken stock", value: 500, quantityText: "500", remainder: "ml chicken stock")
        assertQuantity("2cups flour", value: 2, quantityText: "2", remainder: "cups flour")
        assertQuantity("2T soy sauce", value: 2, quantityText: "2", remainder: "T soy sauce")
        assertQuantity("1½cups", value: 1.5, quantityText: "1½", remainder: "cups")
    }

    func testParenthesisAndCommaAreBoundaries() {
        assertQuantity("1 (14 oz) can", value: 1, quantityText: "1", remainder: "(14 oz) can")
        assertQuantity("1(14 oz) can", value: 1, quantityText: "1", remainder: "(14 oz) can")
        assertQuantity("3, divided", value: 3, quantityText: "3", remainder: ", divided")
        assertQuantity("2", value: 2, quantityText: "2", remainder: "")
        assertQuantity("  2 cups", value: 2, quantityText: "2", remainder: "cups")
    }

    // MARK: - Words

    func testNumberWordsNeedAFollowingSpace() {
        assertQuantity("one large onion", value: 1, quantityText: "one", remainder: "large onion")
        assertQuantity("Two eggs", value: 2, quantityText: "Two", remainder: "eggs")
        assertQuantity("TWELVE  eggs", value: 12, quantityText: "TWELVE", remainder: "eggs")
        XCTAssertNil(parse("twelve"), "no space after the word")
        XCTAssertNil(parse("One-pot pasta"))
        XCTAssertNil(parse("Onion"))
        XCTAssertNil(parse("thirteen eggs"), "only one…twelve")
        XCTAssertNil(parse("half an onion"), "no 'half': inventing 0.5 would be a wrong number")
    }

    func testArticleIsOneOnlyBeforeAUnit() {
        assertQuantity("a pinch of nutmeg", value: 1, quantityText: "a", remainder: "pinch of nutmeg")
        assertQuantity("A can of beans", value: 1, quantityText: "A", remainder: "can of beans")
        assertQuantity("a fl oz of cream", value: 1, quantityText: "a", remainder: "fl oz of cream")
        assertQuantity("a tsp. sugar", value: 1, quantityText: "a", remainder: "tsp. sugar")
        XCTAssertNil(parse("an onion"))
        XCTAssertNil(parse("a large onion"))
        XCTAssertNil(parse("a"))
        XCTAssertNil(parse("a "))
    }

    // MARK: - Not a quantity

    func testLinesThatDoNotStartWithAQuantity() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("   "))
        XCTAssertNil(parse("Juice of 1 lemon"))
        XCTAssertNil(parse("Salt and pepper to taste"))
        XCTAssertNil(parse("For the sauce:"))
    }

    func testNumbersGluedToNonUnitsAreNotQuantities() {
        // A wrong quantity is worse than none: "10" is not how many tortillas.
        XCTAssertNil(parse("10-inch flour tortillas"))
        XCTAssertNil(parse("2% milk"))
        XCTAssertNil(parse("1/2-inch piece ginger"))
        XCTAssertNil(parse("½-inch slices"))
        XCTAssertNil(parse("1/0 cup"), "a zero denominator is not a number")
    }

    func testRangeWithoutASecondNumberIsNotARange() {
        // "1 to taste" — "to" is not followed by a number, so the quantity is 1 and
        // the remainder keeps "to taste" for the splitter's prep-word rule.
        assertQuantity("1 to taste", value: 1, quantityText: "1", remainder: "to taste")
        assertQuantity("2 or so", value: 2, quantityText: "2", remainder: "or so")
    }

    func testParsedQuantityEquality() {
        XCTAssertEqual(ParsedQuantity(value: 1, text: "1"), ParsedQuantity(value: 1, text: "1", rangeText: nil))
        XCTAssertNotEqual(ParsedQuantity(value: 1, text: "1"), ParsedQuantity(value: 1, text: "1", rangeText: "1-2"))
    }

    func testAThousandsCommaAndAnOCRSplitFractionAreNotQuantities() {
        // "1,000" is one number the grammar does not parse, and "1 /2" is OCR for ½:
        // reading either as 1 would be a wrong quantity, which is worse than none.
        XCTAssertNil(QuantityParser.parse(leading: "1,000 g flour"))
        XCTAssertNil(QuantityParser.parse(leading: "1 /2 cup milk"))
        XCTAssertEqual(QuantityParser.parse(leading: "1, diced")?.quantity.value, 1, "a comma before a word is still a boundary")
    }
}
