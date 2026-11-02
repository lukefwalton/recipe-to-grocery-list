import XCTest
@testable import RecipeToGroceryList

/// The ingredient region, proposed before any matcher runs. These are the lines a
/// screenshot of a whole recipe actually contains — headings, an introduction, the
/// list, then the method — not the prepared ingredient lines the golden corpus scores.
final class IngredientBlockTests: XCTestCase {

    func testABlogPageKeepsTheIngredientBlockAndNothingAroundIt() {
        let lines = [
            "Let's get started",
            "This soup is my favorite weeknight dinner and it comes together fast.",
            "Ingredients",
            "2 cups vegetable stock",
            "3 cloves garlic",
            "For the sauce:",
            "1 onion, diced",
            "Instructions",
            "Preheat the oven to 350 and roast until sweet.",
            "Add the garlic and stir.",
        ]
        XCTAssertEqual(IngredientBlock.propose(lines), [
            .sectionHeader,
            .excluded,
            .sectionHeader,
            .ingredient,
            .ingredient,
            .sectionHeader,
            .ingredient,
            .sectionHeader,
            .excluded,
            .excluded,
        ])
    }

    func testCurlyApostropheAndAShoutedHeadingAreTheSameHeading() {
        XCTAssertEqual(IngredientBlock.propose(["Let’s get started!"])[0], .sectionHeader)
        XCTAssertEqual(IngredientBlock.propose(["LET'S GET STARTED"])[0], .sectionHeader)
        XCTAssertEqual(IngredientBlock.propose(["Ingredients (8)"])[0], .sectionHeader)
        XCTAssertEqual(IngredientBlock.propose(["Instructions:"])[0], .sectionHeader)
    }

    func testAPlainIngredientListIsKeptWholeIncludingItsHeaders() {
        let lines = [
            "For the soup:",
            "- 2 cups vegetable stock",
            "3 cloves garlic",
            "Garnish:",
            "1 onion, diced",
        ]
        XCTAssertEqual(IngredientBlock.propose(lines), [
            .sectionHeader, .ingredient, .ingredient, .sectionHeader, .ingredient,
        ])
    }

    func testBareNamesWithoutQuantitiesAreIngredients() {
        XCTAssertEqual(IngredientBlock.propose(["garlic", "onion", "salt"]),
                       [.ingredient, .ingredient, .ingredient])
    }

    func testAGreetingBeforeBareNamesStaysOffTheList() {
        XCTAssertEqual(IngredientBlock.propose(["Welcome", "garlic", "onion"]),
                       [.excluded, .ingredient, .ingredient])
    }

    func testLetsGetStartedAfterTheListEndsTheBlock() {
        let lines = [
            "Ingredients",
            "2 cups vegetable stock",
            "Let's get started",
            "Preheat the oven to 375.",
        ]
        XCTAssertEqual(IngredientBlock.propose(lines), [
            .sectionHeader, .ingredient, .sectionHeader, .excluded,
        ])
    }

    func testPhotoIndicesParseOnlyTheCheckedLines() {
        let lines = [
            "Let's get started",
            "2 cups flour",
            "Preheat the oven to 350 degrees",
        ]
        let admitted = IngredientBlock.admit(lines, selection: .indices([1]))
        XCTAssertEqual(admitted.map(\.role), [.sectionHeader, .ingredient])
        XCTAssertEqual(admitted.map(\.text), ["Let's get started", "2 cups flour"])
    }

    func testProposedBlockDropsBlanksAndBulletDecoration() {
        let admitted = IngredientBlock.admit(["", "- 2 cups flour", "   "], selection: .proposedBlock)
        XCTAssertEqual(admitted.map(\.text), ["2 cups flour"])
        XCTAssertEqual(admitted.map(\.role), [.ingredient])
    }

    func testAllKeepsEveryNonHeaderIncludingAnIntroduction() {
        let admitted = IngredientBlock.admit(["Let's get started", "2 cups flour"], selection: .all)
        XCTAssertEqual(admitted.map(\.role), [.ingredient, .ingredient])
    }
}
