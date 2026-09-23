import XCTest
@testable import RecipeToGroceryList

/// Turning Vision's boxes into lines (spec §5.3). Pure and Foundation-only, so
/// the grouping rule is testable without Vision — which matters, because this is
/// the part of the photo path most likely to be wrong and least likely to be
/// noticed: a bad merge produces a plausible-looking but wrong ingredient line.
///
/// Every expected value here was produced by running a port of `PhotoLineMerger`
/// over these exact boxes (there is no Swift toolchain where this was written).
final class PhotoLineMergerTests: XCTestCase {

    /// Vision's space: origin bottom-left, everything normalized to 0…1.
    private func box(_ text: String, x: Double, y: Double, width: Double = 0.2, height: Double = 0.04) -> RecognizedTextBox {
        RecognizedTextBox(text: text, minX: x, minY: y, width: width, height: height)
    }

    func testSingleColumnReadsTopToBottom() {
        let lines = PhotoLineMerger.lines(from: [
            box("2 cups flour", x: 0.1, y: 0.80),
            box("1 tsp salt", x: 0.1, y: 0.70),
            box("3 eggs", x: 0.1, y: 0.60),
        ])
        XCTAssertEqual(lines, ["2 cups flour", "1 tsp salt", "3 eggs"])
    }

    /// Vision splits one physical line into several observations more often than
    /// not; rejoining them left to right is the whole point of the merge.
    func testBoxesOnOneLineJoinLeftToRight() {
        let lines = PhotoLineMerger.lines(from: [
            box("all-purpose flour", x: 0.35, y: 0.802),
            box("2 cups", x: 0.1, y: 0.80),
        ])
        XCTAssertEqual(lines, ["2 cups all-purpose flour"],
                       "input order doesn't matter; horizontal position does")
    }

    func testSubPixelJitterDoesNotSplitALine() {
        let lines = PhotoLineMerger.lines(from: [
            box("1/2 cup", x: 0.1, y: 0.700),
            box("milk", x: 0.3, y: 0.706),
            box("sugar", x: 0.5, y: 0.695),
        ])
        XCTAssertEqual(lines, ["1/2 cup milk sugar"])
    }

    /// A tall box ("½") and a short one on the same physical line group together
    /// because centres are compared, not bottom edges.
    func testBoxesOfDifferentHeightsOnOneLineStillMerge() {
        let lines = PhotoLineMerger.lines(from: [
            box("1/2", x: 0.1, y: 0.70, height: 0.08),
            box("cup cream", x: 0.25, y: 0.72, height: 0.03),
        ])
        XCTAssertEqual(lines, ["1/2 cup cream"])
    }

    /// **The documented limitation** (spec §5.3): two columns at the same height
    /// are the same line as far as a normalized box is concerned, so they merge.
    /// The screen warns "works best on a single column" before the photo is taken,
    /// and Confirm is where the user fixes it. Asserted so this stays a decision
    /// rather than a surprise.
    func testTwoColumnsOnOneRowInterleaveIntoOneLine() {
        let lines = PhotoLineMerger.lines(from: [
            box("2 cups flour", x: 0.05, y: 0.80),
            box("1 tsp salt", x: 0.55, y: 0.80),
            box("3 eggs", x: 0.05, y: 0.70),
            box("1 cup milk", x: 0.55, y: 0.70),
        ])
        XCTAssertEqual(lines, ["2 cups flour 1 tsp salt", "3 eggs 1 cup milk"])
    }

    func testEmptyAndBlankBoxesAreDropped() {
        let lines = PhotoLineMerger.lines(from: [
            box("", x: 0.1, y: 0.80),
            box("   ", x: 0.3, y: 0.80),
            box("flour", x: 0.5, y: 0.80),
        ])
        XCTAssertEqual(lines, ["flour"])
    }

    func testNothingRecognizedYieldsNoLines() {
        XCTAssertEqual(PhotoLineMerger.lines(from: []), [])
        XCTAssertEqual(PhotoLineMerger.lines(from: [box("", x: 0.1, y: 0.8)]), [])
    }

    func testWhitespaceInsideABoxIsCollapsed() {
        let lines = PhotoLineMerger.lines(from: [
            box("2   cups", x: 0.1, y: 0.8),
            box(" flour ", x: 0.4, y: 0.8),
        ])
        XCTAssertEqual(lines, ["2 cups flour"])
    }

    // MARK: - Median height

    /// The band is half the *median* height, so one oversized drop cap or chapter
    /// heading can't stretch the grouping for the whole page.
    func testMedianHeightIgnoresAnOutlier() {
        let boxes = [
            box("a", x: 0, y: 0.9, height: 0.04),
            box("b", x: 0, y: 0.8, height: 0.04),
            box("HUGE", x: 0, y: 0.7, height: 0.40),
        ]
        XCTAssertEqual(PhotoLineMerger.medianHeight(of: boxes), 0.04, accuracy: 1e-9)
    }

    func testMedianHeightOfAnEvenCountAveragesTheMiddleTwo() {
        let boxes = [
            box("a", x: 0, y: 0.9, height: 0.02),
            box("b", x: 0, y: 0.8, height: 0.04),
            box("c", x: 0, y: 0.7, height: 0.06),
            box("d", x: 0, y: 0.6, height: 0.08),
        ]
        XCTAssertEqual(PhotoLineMerger.medianHeight(of: boxes), 0.05, accuracy: 1e-9)
    }

    func testBoxCenterIsTheVerticalMiddle() {
        XCTAssertEqual(box("x", x: 0, y: 0.5, height: 0.1).centerY, 0.55, accuracy: 1e-9)
    }

    // MARK: - Recognizer seam

    func testTheNoopRecognizerRecognizesNothing() async {
        let lines = await NoopTextRecognizer().recognizeLines(in: Data())
        XCTAssertEqual(lines, [], "no Vision → an empty read, and the screen offers another photo")
    }
}
