import XCTest
@testable import RecipeToGroceryList

/// §5.2: split, trim, drop empties, strip bullets and numbering, classify headers.
final class LineCleanerTests: XCTestCase {

    // MARK: - stripBullet

    func testStripsLeadingBulletGlyphs() {
        XCTAssertEqual(LineCleaner.stripBullet("- 2 cups flour"), "2 cups flour")
        XCTAssertEqual(LineCleaner.stripBullet("-1 cup"), "1 cup")
        XCTAssertEqual(LineCleaner.stripBullet("• salt"), "salt")
        XCTAssertEqual(LineCleaner.stripBullet("* pepper"), "pepper")
        XCTAssertEqual(LineCleaner.stripBullet("· nutmeg"), "nutmeg")
        XCTAssertEqual(LineCleaner.stripBullet("▢ 1 onion"), "1 onion")
        XCTAssertEqual(LineCleaner.stripBullet("☐ 1 onion"), "1 onion")
        XCTAssertEqual(LineCleaner.stripBullet("✓ done"), "done")
        XCTAssertEqual(LineCleaner.stripBullet("> quoted"), "quoted")
        XCTAssertEqual(LineCleaner.stripBullet("– 2 eggs"), "2 eggs")
        XCTAssertEqual(LineCleaner.stripBullet("— 2 eggs"), "2 eggs")
    }

    func testStripsListNumbering() {
        XCTAssertEqual(LineCleaner.stripBullet("1. flour"), "flour")
        XCTAssertEqual(LineCleaner.stripBullet("12. flour"), "flour")
        XCTAssertEqual(LineCleaner.stripBullet("1) flour"), "flour")
        XCTAssertEqual(LineCleaner.stripBullet("(1) flour"), "flour")
        XCTAssertEqual(LineCleaner.stripBullet("① flour"), "flour")
        XCTAssertEqual(LineCleaner.stripBullet("⑳ flour"), "flour")
        XCTAssertEqual(LineCleaner.stripBullet("1. 2 cups sugar"), "2 cups sugar")
        XCTAssertEqual(LineCleaner.stripBullet("3."), "", "numbering alone leaves nothing")
    }

    func testDoesNotStripDecimalsRangesOrParentheticals() {
        XCTAssertEqual(LineCleaner.stripBullet("1.5 cups sugar"), "1.5 cups sugar")
        XCTAssertEqual(LineCleaner.stripBullet("2 - 3 lemons"), "2 - 3 lemons")
        XCTAssertEqual(LineCleaner.stripBullet("10-inch pan"), "10-inch pan")
        XCTAssertEqual(LineCleaner.stripBullet("(14.5 oz) can tomatoes"), "(14.5 oz) can tomatoes")
        XCTAssertEqual(LineCleaner.stripBullet("1234. x"), "1234. x", "four digits are not list numbering")
        XCTAssertEqual(LineCleaner.stripBullet("2 cups flour"), "2 cups flour")
    }

    func testStripsDoubleDecorationAndTrims() {
        XCTAssertEqual(LineCleaner.stripBullet("- - x"), "x")
        XCTAssertEqual(LineCleaner.stripBullet("- 1. flour"), "flour")
        XCTAssertEqual(LineCleaner.stripBullet("1. - flour"), "flour")
        XCTAssertEqual(LineCleaner.stripBullet("   2 cups   "), "2 cups")
        XCTAssertEqual(LineCleaner.stripBullet("—"), "")
        XCTAssertEqual(LineCleaner.stripBullet(""), "")
    }

    // MARK: - isSectionHeader

    func testHeadersEndWithAColonAndHaveNoDigit() {
        XCTAssertTrue(LineCleaner.isSectionHeader("For the sauce:"))
        XCTAssertTrue(LineCleaner.isSectionHeader("Ingredients:"))
        XCTAssertTrue(LineCleaner.isSectionHeader("  Toppings:  "))
        XCTAssertFalse(LineCleaner.isSectionHeader("2 cups:"))
        XCTAssertFalse(LineCleaner.isSectionHeader("½ cup:"), "a vulgar fraction counts as a digit")
        XCTAssertFalse(LineCleaner.isSectionHeader("Salt"))
        XCTAssertFalse(LineCleaner.isSectionHeader("Note: use fresh basil"))
        XCTAssertFalse(LineCleaner.isSectionHeader(""))
    }

    // MARK: - clean / cleanLines

    func testCleanSplitsTrimsDropsEmptiesAndClassifies() {
        let text = "For the sauce:\n- 2 cups flour\n\n  \n* 1 tsp salt\r\nSalt to taste"
        XCTAssertEqual(LineCleaner.clean(text), [
            .sectionHeader("For the sauce:"),
            .ingredient("2 cups flour"),
            .ingredient("1 tsp salt"),
            .ingredient("Salt to taste"),
        ])
    }

    func testCleanLinesWorksPerElement() {
        XCTAssertEqual(LineCleaner.cleanLines(["", "  ", "• Onion", "Garnish:"]), [
            .ingredient("Onion"),
            .sectionHeader("Garnish:"),
        ])
        XCTAssertEqual(LineCleaner.cleanLines([]), [])
    }

    func testCleanedLineTextAndKind() {
        XCTAssertEqual(CleanedLine.ingredient("x").text, "x")
        XCTAssertEqual(CleanedLine.sectionHeader("y:").text, "y:")
        XCTAssertTrue(CleanedLine.sectionHeader("y:").isSectionHeader)
        XCTAssertFalse(CleanedLine.ingredient("x").isSectionHeader)
    }

    func testNothingButEmptyLinesIsDropped() {
        // "Nothing silently dropped": a decorated line with content survives; only
        // whitespace/decoration-only lines vanish.
        XCTAssertEqual(LineCleaner.clean("-\n•\n  \n").count, 0)
        XCTAssertEqual(LineCleaner.clean("- a").count, 1)
    }
}
