import XCTest
@testable import RecipeToGroceryList

/// The small amount of HTML handling the URL path needs (spec §5.1). Entities
/// matter here because fractions arrive as `&frac12;` or `&#189;` far more often
/// than as `½`, and a mis-decoded fraction would reach the splitter as a quantity
/// it can't read.
final class HTMLEntitiesTests: XCTestCase {

    func testNamedEntities() {
        XCTAssertEqual(HTMLEntities.decode("Salt &amp; pepper"), "Salt & pepper")
        XCTAssertEqual(HTMLEntities.decode("&frac12; cup"), "½ cup")
        XCTAssertEqual(HTMLEntities.decode("&frac14; teaspoon"), "¼ teaspoon")
        XCTAssertEqual(HTMLEntities.decode("2&ndash;3 tablespoons"), "2–3 tablespoons")
        XCTAssertEqual(HTMLEntities.decode("cook&rsquo;s note"), "cook’s note")
    }

    func testNumericEntitiesInBothBases() {
        XCTAssertEqual(HTMLEntities.decode("&#189; cup"), "½ cup")
        XCTAssertEqual(HTMLEntities.decode("&#x00BD; cup"), "½ cup")
        XCTAssertEqual(HTMLEntities.decode("&#39;"), "'")
    }

    func testCaseInsensitiveNamedLookup() {
        XCTAssertEqual(HTMLEntities.decode("&AMP;"), "&")
    }

    /// An unknown or unterminated reference is left exactly as written: showing
    /// `&foo;` is honest, and guessing at it is not.
    func testUnknownAndUnterminatedReferencesAreLeftAlone() {
        XCTAssertEqual(HTMLEntities.decode("&foo;"), "&foo;")
        XCTAssertEqual(HTMLEntities.decode("salt & pepper"), "salt & pepper")
        XCTAssertEqual(HTMLEntities.decode("100% &"), "100% &")
        XCTAssertEqual(HTMLEntities.decode("&verylongentityname;"), "&verylongentityname;",
                       "the scan window is short, so a stray & never swallows a sentence")
    }

    func testTextWithoutAmpersandIsReturnedUnchanged() {
        XCTAssertEqual(HTMLEntities.decode("2 cups flour"), "2 cups flour")
    }

    func testStripTagsDropsMarkupAndDecodes() {
        XCTAssertEqual(HTMLEntities.stripTags("<b>2</b> cups &amp; more"), "2 cups & more")
    }

    /// `<script>` and `<style>` go with their contents — otherwise a page's
    /// JavaScript would land in an ingredient line.
    func testStripTagsRemovesScriptAndStyleBlocksEntirely() {
        XCTAssertEqual(HTMLEntities.collapseWhitespace(
            HTMLEntities.stripTags("a<script>var x = 1;</script>b")), "a b")
        XCTAssertEqual(HTMLEntities.collapseWhitespace(
            HTMLEntities.stripTags("a<style>.x { color: red }</style>b")), "a b")
    }

    /// Block boundaries become whitespace, so two list items never run into one word.
    func testBlockTagsBecomeLineBreaks() {
        XCTAssertEqual(HTMLEntities.collapseWhitespace(
            HTMLEntities.stripTags("<li>flour</li><li>sugar</li>")), "flour sugar")
    }

    /// A `<` with no `>` after it is prose, not a tag — recipes say "heat to
    /// < 200°" — so the rest of the text survives intact.
    func testUnclosedAngleBracketIsTreatedAsText() {
        XCTAssertEqual(HTMLEntities.stripTags("heat to < 200 degrees"), "heat to < 200 degrees")
        XCTAssertEqual(HTMLEntities.stripTags("2 < 3"), "2 < 3")
    }

    func testCollapseWhitespaceIncludingNonBreakingSpaces() {
        XCTAssertEqual(HTMLEntities.collapseWhitespace("  2   cups \n flour "), "2 cups flour")
        XCTAssertEqual(HTMLEntities.collapseWhitespace("2\u{00A0}cups"), "2 cups",
                       "a decoded &nbsp; is a space like any other")
    }

    func testCleanIsDecodeThenCollapse() {
        XCTAssertEqual(HTMLEntities.clean("  &frac12;&nbsp;cup   milk "), "½ cup milk")
    }

    func testTagName() {
        XCTAssertEqual(HTMLEntities.tagName("li class='x'"), "li")
        XCTAssertEqual(HTMLEntities.tagName("/DIV"), "div")
        XCTAssertEqual(HTMLEntities.tagName("br/"), "br")
    }
}
