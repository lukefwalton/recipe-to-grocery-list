import XCTest
@testable import RecipeToGroceryList

/// The one timestamp format, shared by the store's columns and the Share
/// Extension's inbox. A round trip is the whole contract; the rest is refusing to
/// invent a date for text it can't read.
final class RecipeDateFormatTests: XCTestCase {

    func testRoundTripsToTheSecond() {
        // ISO8601 with `.withInternetDateTime` has second resolution, so compare
        // against a whole-second date rather than "now".
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        let text = RecipeDateFormat.string(date)
        XCTAssertEqual(RecipeDateFormat.date(text), date)
    }

    func testFormatIsInternetDateTime() {
        let text = RecipeDateFormat.string(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(text, "1970-01-01T00:00:00Z")
    }

    func testUnreadableInputIsNilRatherThanAFabricatedDate() {
        XCTAssertNil(RecipeDateFormat.date(nil))
        XCTAssertNil(RecipeDateFormat.date(""))
        XCTAssertNil(RecipeDateFormat.date("yesterday"))
        XCTAssertNil(RecipeDateFormat.date("2026-09-17"), "a bare date is not the format the store writes")
    }

    func testParsesAnOffsetTimestamp() {
        XCTAssertEqual(RecipeDateFormat.date("1970-01-01T01:00:00+01:00"),
                       Date(timeIntervalSince1970: 0))
    }
}
