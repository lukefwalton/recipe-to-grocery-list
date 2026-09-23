import XCTest
@testable import RecipeToGroceryList

/// §7.2 splitter: the contract's key cases plus the ordering rules. Every expected
/// tuple was produced by the Python design prototype (`splitter_check.py`) first.
final class IngredientLineSplitterTests: XCTestCase {

    private func assertSplit(_ input: String,
                             quantity: Double?,
                             unitKey: String?,
                             name: String,
                             note: String?,
                             unresolved: Bool = false,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        let result = IngredientLineSplitter.split(input)
        if let quantity = quantity {
            if let actual = result.quantity {
                XCTAssertEqual(actual, quantity, accuracy: 1e-9, "quantity of \(input.debugDescription)", file: file, line: line)
            } else {
                XCTFail("expected quantity \(quantity) for \(input.debugDescription), got nil", file: file, line: line)
            }
        } else {
            XCTAssertNil(result.quantity, "quantity of \(input.debugDescription)", file: file, line: line)
        }
        XCTAssertEqual(result.unitKey, unitKey, "unit of \(input.debugDescription)", file: file, line: line)
        XCTAssertEqual(result.name, name, "name of \(input.debugDescription)", file: file, line: line)
        XCTAssertEqual(result.note, note, "note of \(input.debugDescription)", file: file, line: line)
        XCTAssertEqual(result.isUnresolved, unresolved, "unresolved flag of \(input.debugDescription)", file: file, line: line)
        XCTAssertEqual(result.rawLine, input, "rawLine is the input, unchanged", file: file, line: line)
    }

    // MARK: - The contract's key cases

    func testKeyCasesFromTheContract() {
        assertSplit("1 1/2 tsp. kosher salt", quantity: 1.5, unitKey: "tsp", name: "kosher salt", note: nil)
        assertSplit("½ cup heavy cream", quantity: 0.5, unitKey: "cup", name: "heavy cream", note: nil)
        assertSplit("1 (14.5 oz) can diced tomatoes", quantity: 1, unitKey: "can", name: "diced tomatoes", note: "14.5 oz")
        assertSplit("2–3 tablespoons olive oil, divided", quantity: 2, unitKey: "tbsp", name: "olive oil", note: "2–3, divided")
        assertSplit("a pinch of nutmeg", quantity: 1, unitKey: "pinch", name: "nutmeg", note: nil)
        assertSplit("one large onion, diced", quantity: 1, unitKey: nil, name: "onion", note: "large, diced")
        assertSplit("500ml chicken stock", quantity: 500, unitKey: "ml", name: "chicken stock", note: nil)
        assertSplit("2 T soy sauce", quantity: 2, unitKey: "tbsp", name: "soy sauce", note: nil)
        assertSplit("1 t vanilla extract", quantity: 1, unitKey: "tsp", name: "vanilla extract", note: nil)
        assertSplit("Juice of 1 lemon", quantity: nil, unitKey: nil, name: "Juice of 1 lemon", note: nil)
        assertSplit("Salt and pepper to taste", quantity: nil, unitKey: nil, name: "Salt and pepper", note: "to taste")
        assertSplit("3 cloves garlic, minced", quantity: 3, unitKey: "clove", name: "garlic", note: "minced")
        assertSplit("2cups flour", quantity: 2, unitKey: "cup", name: "flour", note: nil)
    }

    func testNameKeepsTheAuthorsCasing() {
        assertSplit("3 Tomatoes", quantity: 3, unitKey: nil, name: "Tomatoes", note: nil)
        assertSplit("Large eggs", quantity: nil, unitKey: nil, name: "eggs", note: "Large")
        XCTAssertEqual(IngredientLineSplitter.split("2 cups Heavy Cream").name, "Heavy Cream")
    }

    // MARK: - Bullets and headers

    func testBulletsAndNumberingAreStrippedFirst() {
        assertSplit("- 2 cups all-purpose flour", quantity: 2, unitKey: "cup", name: "all-purpose flour", note: nil)
        assertSplit("• 1 bunch cilantro", quantity: 1, unitKey: "bunch", name: "cilantro", note: nil)
        assertSplit("1. 2 cups sugar", quantity: 2, unitKey: "cup", name: "sugar", note: nil)
        assertSplit("(1) 2 cups rice", quantity: 2, unitKey: "cup", name: "rice", note: nil)
        assertSplit("① 1 cup rice", quantity: 1, unitKey: "cup", name: "rice", note: nil)
        assertSplit("1.5 cups sugar", quantity: 1.5, unitKey: "cup", name: "sugar", note: nil)
    }

    func testHeadersAndEmptyLinesSplitHarmlessly() {
        // LineCleaner keeps these out of the splitter in the pipeline; called directly
        // they are simply unresolved-free lines with no quantity.
        assertSplit("For the sauce:", quantity: nil, unitKey: nil, name: "For the sauce:", note: nil)
        let empty = IngredientLineSplitter.split("")
        XCTAssertEqual(empty.name, "")
        XCTAssertTrue(empty.isUnresolved)
        XCTAssertNil(empty.quantity)
    }

    // MARK: - Quantities and units

    func testQuantitySpellings() {
        assertSplit("1½ cups milk", quantity: 1.5, unitKey: "cup", name: "milk", note: nil)
        assertSplit("1 ½ cups milk", quantity: 1.5, unitKey: "cup", name: "milk", note: nil)
        assertSplit("1-1/2 cups milk", quantity: 1.5, unitKey: "cup", name: "milk", note: nil)
        assertSplit(".5 cup sugar", quantity: 0.5, unitKey: "cup", name: "sugar", note: nil)
        assertSplit("Two eggs", quantity: 2, unitKey: nil, name: "eggs", note: nil)
        XCTAssertEqual(IngredientLineSplitter.split("1 1/2 tsp salt").quantityText, "1 1/2")
        XCTAssertEqual(IngredientLineSplitter.split("½ cup").quantityText, "½")
        XCTAssertNil(IngredientLineSplitter.split("Salt").quantityText)
    }

    func testRangesGoIntoTheNote() {
        assertSplit("2 to 3 cups spinach", quantity: 2, unitKey: "cup", name: "spinach", note: "2 to 3")
        assertSplit("2 or 3 lemons", quantity: 2, unitKey: nil, name: "lemons", note: "2 or 3")
        assertSplit("2 - 3 lemons", quantity: 2, unitKey: nil, name: "lemons", note: "2 - 3")
        assertSplit("6-8 cups water", quantity: 6, unitKey: "cup", name: "water", note: "6-8")
    }

    func testNumbersThatAreNotQuantitiesStayInTheName() {
        assertSplit("10-inch flour tortillas", quantity: nil, unitKey: nil, name: "10-inch flour tortillas", note: nil)
        assertSplit("2% milk", quantity: nil, unitKey: nil, name: "2% milk", note: nil)
        assertSplit("1/2-inch piece ginger", quantity: nil, unitKey: nil, name: "1/2-inch piece ginger", note: nil)
    }

    func testUnitVariants() {
        assertSplit("1 cup of sugar", quantity: 1, unitKey: "cup", name: "sugar", note: nil)
        assertSplit("1 c sugar", quantity: 1, unitKey: "cup", name: "sugar", note: nil)
        assertSplit("3 l water", quantity: 3, unitKey: "l", name: "water", note: nil)
        assertSplit("4 fl oz milk", quantity: 4, unitKey: "floz", name: "milk", note: nil)
        assertSplit("a fl oz of cream", quantity: 1, unitKey: "floz", name: "cream", note: nil)
        assertSplit("1 lb. ground beef", quantity: 1, unitKey: "lb", name: "ground beef", note: nil)
        assertSplit("1 tsp.salt", quantity: 1, unitKey: "tsp", name: "salt", note: nil)
        assertSplit("1 whole chicken", quantity: 1, unitKey: "piece", name: "chicken", note: nil)
        assertSplit("2 sticks celery", quantity: 2, unitKey: "stick", name: "celery", note: nil)
        assertSplit("A can of beans", quantity: 1, unitKey: "can", name: "beans", note: nil)
    }

    func testUnitTextKeepsTheAuthorsSpelling() {
        XCTAssertEqual(IngredientLineSplitter.split("2 Tbsp. olive oil").unitText, "Tbsp")
        XCTAssertEqual(IngredientLineSplitter.split("2 Tbsp. olive oil").unitKey, "tbsp")
        XCTAssertEqual(IngredientLineSplitter.split("2 cups flour").unitText, "cups")
        XCTAssertNil(IngredientLineSplitter.split("3 large eggs").unitText, "'l' inside 'large' is not a liter")
    }

    func testUnitIsOnlyReadAfterAQuantity() {
        assertSplit("Pinch of salt", quantity: nil, unitKey: nil, name: "Pinch of salt", note: nil)
        assertSplit("an onion", quantity: nil, unitKey: nil, name: "an onion", note: nil)
    }

    // MARK: - Notes

    func testParentheticalsAnywhereBecomeNotes() {
        assertSplit("1 cup walnuts (optional)", quantity: 1, unitKey: "cup", name: "walnuts", note: "optional")
        assertSplit("1 (about 1 lb) eggplant", quantity: 1, unitKey: nil, name: "eggplant", note: "about 1 lb")
        assertSplit("2 tbsp butter, melted (optional)", quantity: 2, unitKey: "tbsp", name: "butter", note: "optional, melted")
        XCTAssertEqual(IngredientLineSplitter.extractParentheticals("a (b (c)) d (e)").notes, ["b (c)", "e"])
        XCTAssertEqual(IngredientLineSplitter.extractParentheticals("a (b (c)) d (e)").text, "a   d  ")
        XCTAssertEqual(IngredientLineSplitter.extractParentheticals("1 cup (about").notes, ["about"], "unbalanced opener runs to the end")
        XCTAssertEqual(IngredientLineSplitter.extractParentheticals("x () y").notes, [])
    }

    func testTextAfterTheFirstCommaIsNote() {
        assertSplit("2 cups flour, sifted, divided", quantity: 2, unitKey: "cup", name: "flour", note: "sifted, divided")
        assertSplit("2 tsp fresh thyme, finely chopped", quantity: 2, unitKey: "tsp", name: "fresh thyme", note: "finely chopped")
        assertSplit("olive oil,", quantity: nil, unitKey: nil, name: "olive oil", note: nil)
    }

    func testTrailingPrepWordsMoveToTheNote() {
        assertSplit("1 onion thinly sliced", quantity: 1, unitKey: nil, name: "onion", note: "thinly sliced")
        assertSplit("2 cups spinach chopped", quantity: 2, unitKey: "cup", name: "spinach", note: "chopped")
        assertSplit("1 cup nuts optional", quantity: 1, unitKey: "cup", name: "nuts", note: "optional")
        assertSplit("Salt to taste", quantity: nil, unitKey: nil, name: "Salt", note: "to taste")
        assertSplit("Butter at room temperature", quantity: nil, unitKey: nil, name: "Butter", note: "at room temperature")
        assertSplit("Lime wedges for serving", quantity: nil, unitKey: nil, name: "Lime wedges", note: "for serving")
    }

    func testPlusMoreIsAnOpenEndedNote() {
        assertSplit("2 tbsp olive oil plus more for frying", quantity: 2, unitKey: "tbsp", name: "olive oil", note: "plus more for frying")
        assertSplit("Salt, plus more for seasoning", quantity: nil, unitKey: nil, name: "Salt", note: "plus more for seasoning")
    }

    func testLeadingSizeWordsMoveToTheNote() {
        assertSplit("1 large egg", quantity: 1, unitKey: nil, name: "egg", note: "large")
        assertSplit("3 large eggs, beaten", quantity: 3, unitKey: nil, name: "eggs", note: "large, beaten")
        assertSplit("3 large potatoes", quantity: 3, unitKey: nil, name: "potatoes", note: "large")
        assertSplit("2 extra-large eggs", quantity: 2, unitKey: nil, name: "eggs", note: "extra-large")
        assertSplit("1 medium onion", quantity: 1, unitKey: nil, name: "onion", note: "medium")
        assertSplit("Large eggs", quantity: nil, unitKey: nil, name: "eggs", note: "Large")
    }

    func testNoteOrderIsParentheticalRangeSizePrepComma() {
        assertSplit("2-3 large (about 1 lb) potatoes peeled, halved", quantity: 2, unitKey: nil,
                    name: "potatoes", note: "about 1 lb, 2-3, large, peeled, halved")
    }

    // MARK: - Unresolved

    func testEmptyNameIsUnresolvedAndKeepsTheLine() {
        assertSplit("2 cups", quantity: 2, unitKey: "cup", name: "2 cups", note: nil, unresolved: true)
        assertSplit("- 2 cups", quantity: 2, unitKey: "cup", name: "2 cups", note: nil, unresolved: true)
        assertSplit("to taste", quantity: nil, unitKey: nil, name: "to taste", note: "to taste", unresolved: true)
        assertSplit("(optional)", quantity: nil, unitKey: nil, name: "(optional)", note: "optional", unresolved: true)
    }

    // MARK: - Exposed word lists

    func testExposedWordListsContainTheContractsWords() {
        for word in ["diced", "minced", "chopped", "sliced", "divided", "to taste", "optional", "for serving", "for garnish",
                     "peeled", "crushed", "grated", "shredded", "melted", "softened", "beaten", "cubed", "halved", "quartered",
                     "thinly sliced", "finely chopped", "roughly chopped", "at room temperature"] {
            XCTAssertTrue(IngredientLineSplitter.prepWords.contains(word), word)
        }
        for word in ["large", "medium", "small", "big", "extra-large"] {
            XCTAssertTrue(IngredientLineSplitter.sizeWords.contains(word), word)
        }
        XCTAssertEqual(IngredientLineSplitter.openEndedNoteMarker, "plus more")
        XCTAssertEqual(Set(IngredientLineSplitter.prepWords).count, IngredientLineSplitter.prepWords.count, "no duplicates")
    }

    func testStructuredLineDefaults() {
        let line = StructuredLine(rawLine: "x", name: "x")
        XCTAssertNil(line.quantity)
        XCTAssertNil(line.unitKey)
        XCTAssertNil(line.note)
        XCTAssertFalse(line.isUnresolved)
        XCTAssertEqual(line, StructuredLine(rawLine: "x", quantity: nil, quantityText: nil, unitKey: nil, unitText: nil, name: "x", note: nil, isUnresolved: false))
    }
}
