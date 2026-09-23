import XCTest
@testable import RecipeToGroceryList

/// §8 display: common eighths/thirds as fraction glyphs, integers bare, anything
/// else with one decimal — and never a conversion.
final class QuantityFormatTests: XCTestCase {

    func testIntegersAreBare() {
        XCTAssertEqual(QuantityFormat.string(2), "2")
        XCTAssertEqual(QuantityFormat.string(0), "0")
        XCTAssertEqual(QuantityFormat.string(500), "500")
        XCTAssertEqual(QuantityFormat.string(2.0000001), "2", "floating-point noise below the tolerance rounds away")
        XCTAssertEqual(QuantityFormat.string(2.999), "3")
    }

    func testCommonFractionsUseGlyphs() {
        XCTAssertEqual(QuantityFormat.string(0.5), "½")
        XCTAssertEqual(QuantityFormat.string(0.25), "¼")
        XCTAssertEqual(QuantityFormat.string(0.75), "¾")
        XCTAssertEqual(QuantityFormat.string(1.0 / 3.0), "⅓")
        XCTAssertEqual(QuantityFormat.string(2.0 / 3.0), "⅔")
        XCTAssertEqual(QuantityFormat.string(0.125), "⅛")
        XCTAssertEqual(QuantityFormat.string(0.375), "⅜")
        XCTAssertEqual(QuantityFormat.string(0.625), "⅝")
        XCTAssertEqual(QuantityFormat.string(0.875), "⅞")
    }

    func testMixedNumbersKeepTheWholePart() {
        XCTAssertEqual(QuantityFormat.string(1.5), "1½")
        XCTAssertEqual(QuantityFormat.string(2.25), "2¼")
        XCTAssertEqual(QuantityFormat.string(1.125), "1⅛")
        XCTAssertEqual(QuantityFormat.string(4.0 / 3.0), "1⅓")
    }

    func testOtherValuesGetOneDecimal() {
        XCTAssertEqual(QuantityFormat.string(0.4), "0.4")
        XCTAssertEqual(QuantityFormat.string(0.6), "0.6", "0.6 is not within tolerance of ⅝")
        XCTAssertEqual(QuantityFormat.string(1.06), "1.1")
        XCTAssertEqual(QuantityFormat.string(2.96), "3", "one-decimal rounding that lands on an integer is shown bare")
        XCTAssertEqual(QuantityFormat.string(2.2), "2.2")
        XCTAssertEqual(QuantityFormat.string(12.34), "12⅓", "within the 0.01 tolerance of a third — the tolerance is deliberate (§8)")
    }

    func testNonFiniteIsEmpty() {
        XCTAssertEqual(QuantityFormat.string(.nan), "")
        XCTAssertEqual(QuantityFormat.string(.infinity), "")
    }

    func testAmountWithUnit() {
        XCTAssertEqual(QuantityFormat.string(quantity: 2, unitKey: "cup"), "2 cups")
        XCTAssertEqual(QuantityFormat.string(quantity: 1, unitKey: "cup"), "1 cup")
        XCTAssertEqual(QuantityFormat.string(quantity: 0.5, unitKey: "tsp"), "½ tsp")
        XCTAssertEqual(QuantityFormat.string(quantity: 1, unitKey: "can"), "1 can")
        XCTAssertEqual(QuantityFormat.string(quantity: 2, unitKey: "floz"), "2 fl oz")
        XCTAssertEqual(QuantityFormat.string(quantity: 500, unitKey: "ml"), "500 ml")
    }

    func testAmountWithoutUnitOrQuantity() {
        XCTAssertEqual(QuantityFormat.string(quantity: 3, unitKey: nil), "3")
        XCTAssertEqual(QuantityFormat.string(quantity: nil, unitKey: "cup"), "cup")
        XCTAssertEqual(QuantityFormat.string(quantity: nil, unitKey: nil), "")
    }

    func testUnitTextIsUsedOnlyWhenThereIsNoKey() {
        XCTAssertEqual(QuantityFormat.string(quantity: nil, unitKey: nil, unitText: "handful"), "handful")
        XCTAssertEqual(QuantityFormat.string(quantity: 2, unitKey: nil, unitText: "handfuls"), "2 handfuls")
        XCTAssertEqual(QuantityFormat.string(quantity: 2, unitKey: "cup", unitText: "Cups"), "2 cups", "a known key renders its own display name")
    }

    func testUnknownKeyRendersTheKeyItself() {
        XCTAssertEqual(QuantityFormat.string(quantity: 1, unitKey: "zzz"), "1 zzz")
    }

    func testFractionTableCoversEighthsAndThirds() {
        let glyphs = QuantityFormat.fractions.map { $0.glyph }
        XCTAssertEqual(glyphs, ["⅛", "¼", "⅓", "⅜", "½", "⅝", "⅔", "¾", "⅞"])
        let values = QuantityFormat.fractions.map { $0.value }
        XCTAssertEqual(values, values.sorted(), "ascending, so the first tolerant match is the nearest")
    }
}
