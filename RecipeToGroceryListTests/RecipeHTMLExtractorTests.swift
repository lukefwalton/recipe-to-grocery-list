import XCTest
@testable import RecipeToGroceryList

/// Extraction runs entirely offline (spec §11: "there is no network in tests"):
/// every case is either an inline HTML string or one of the saved pages in
/// `Fixtures/html/`, which are hand-written stand-ins for the shapes real recipe
/// sites publish — a plain JSON-LD object, a Yoast-style `@graph`, a `@type`
/// array, a top-level array, two blocks with a CDATA wrapper, and a
/// microdata-only page — plus one page with no recipe at all.
///
/// The expected values were produced by running a port of `RecipeHTMLExtractor`
/// over these exact files (there is no Swift toolchain where this was written), so
/// a failure here means the Swift and that reading disagree.
final class RecipeHTMLExtractorTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "html"),
                                "\(name).html is missing from the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - JSON-LD

    func testSimpleRecipeObject() throws {
        let extracted = try XCTUnwrap(RecipeHTMLExtractor.extract(from: fixture("jsonld_simple")))
        XCTAssertEqual(extracted.title, "Weeknight Lentil Soup")
        XCTAssertEqual(extracted.servingsText, "Serves 4")
        XCTAssertEqual(extracted.ingredientLines, [
            "2 tablespoons olive oil",
            "1 onion, diced",
            "3 cloves garlic, minced",
            "1 cup red lentils, rinsed",
            "4 cups vegetable broth",
            "Salt and pepper, to taste",
        ])
    }

    /// The common WordPress/Yoast shape: the Recipe is one node among several
    /// under `@graph`, the block uses single-quoted attributes, and the yield is
    /// an array whose first entry wins.
    func testGraphWrapperFindsTheRecipeAmongOtherNodes() throws {
        let extracted = try XCTUnwrap(RecipeHTMLExtractor.extract(from: fixture("jsonld_graph")))
        XCTAssertEqual(extracted.title, "Mushroom Risotto")
        XCTAssertEqual(extracted.servingsText, "4", "recipeYield as an array takes the first entry")
        XCTAssertEqual(extracted.ingredientLines.first, "1½ cups arborio rice",
                       "numeric entities inside JSON strings are decoded after parsing")
        XCTAssertEqual(extracted.ingredientLines.last, "½ cup grated parmesan")
        XCTAssertEqual(extracted.ingredientLines.count, 6)
    }

    func testTypeArrayAndNumericYield() throws {
        let extracted = try XCTUnwrap(RecipeHTMLExtractor.extract(from: fixture("jsonld_type_array")))
        XCTAssertEqual(extracted.title, "Skillet Cornbread")
        XCTAssertEqual(extracted.servingsText, "8", "a numeric recipeYield is stringified, not dropped")
        XCTAssertEqual(extracted.ingredientLines[3], "1 ½ cups buttermilk")
        XCTAssertEqual(extracted.ingredientLines.count, 6)
    }

    func testTopLevelArrayWithAURLTypeAndAnOrganizationSibling() throws {
        let extracted = try XCTUnwrap(RecipeHTMLExtractor.extract(from: fixture("jsonld_array_toplevel")))
        XCTAssertEqual(extracted.title, "Chana Masala")
        XCTAssertEqual(extracted.ingredientLines.count, 6)
        XCTAssertEqual(extracted.ingredientLines[4], "1 (14.5 oz) can diced tomatoes")
    }

    /// Two blocks, the first an Organization, the second the recipe wrapped in the
    /// conventional `//<![CDATA[ … //]]>` form (whose trailing `//` is not JSON).
    func testSecondBlockWinsAndCDATAIsUnwrapped() throws {
        let extracted = try XCTUnwrap(RecipeHTMLExtractor.extract(from: fixture("jsonld_two_blocks")))
        XCTAssertEqual(extracted.title, "Brown Butter Banana Bread")
        XCTAssertEqual(extracted.servingsText, "1 loaf")
        XCTAssertEqual(extracted.ingredientLines[1], "½ cup butter, browned")
        XCTAssertEqual(extracted.ingredientLines.count, 6)
    }

    func testPageWithNoRecipeExtractsNothing() throws {
        XCTAssertNil(try RecipeHTMLExtractor.extract(from: fixture("no_recipe")),
                     "a BlogPosting is not a Recipe — the Link screen shows its dead end instead of guessing")
    }

    // MARK: - JSON-LD scanner edge cases (inline)

    func testMalformedBlockNeverCostsThePageItsOtherBlocks() {
        let html = """
        <script type="application/ld+json">{ this is not json </script>
        <script type="application/ld+json">
        {"@type":"Recipe","name":"Salad","recipeIngredient":["1 head lettuce"]}
        </script>
        """
        let extracted = RecipeHTMLExtractor.extract(from: html)
        XCTAssertEqual(extracted?.ingredientLines, ["1 head lettuce"])
    }

    func testAttributeOrderAndQuoteStyleDoNotMatter() {
        let html = """
        <script class='x' type='application/ld+json' data-y="1">
        {"@type":"Recipe","recipeIngredient":"1 cup rice"}
        </script>
        """
        XCTAssertEqual(RecipeHTMLExtractor.extract(from: html)?.ingredientLines, ["1 cup rice"],
                       "a single ingredient string is a one-line list")
    }

    func testNonRecipeScriptBlocksAreIgnored() {
        let html = """
        <script>var x = {"@type":"Recipe","recipeIngredient":["1 cup sugar"]};</script>
        <script type="application/json">{"@type":"Recipe","recipeIngredient":["1 cup salt"]}</script>
        """
        XCTAssertNil(RecipeHTMLExtractor.extract(from: html),
                     "only application/ld+json blocks are read")
    }

    func testTheRecipeWithTheMostIngredientsWins() {
        let html = """
        <script type="application/ld+json">
        [{"@type":"Recipe","name":"Related","recipeIngredient":["1 egg"]},
         {"@type":"Recipe","name":"Main","recipeIngredient":["1 egg","2 cups flour","1 cup milk"]}]
        </script>
        """
        let extracted = RecipeHTMLExtractor.extract(from: html)
        XCTAssertEqual(extracted?.title, "Main", "the page is about the recipe with the real ingredient list")
        XCTAssertEqual(extracted?.ingredientLines.count, 3)
    }

    func testRecipeNodeWithoutIngredientsIsNotARecipeWeCanUse() {
        let html = """
        <script type="application/ld+json">{"@type":"Recipe","name":"Stub"}</script>
        """
        XCTAssertNil(RecipeHTMLExtractor.extract(from: html))
    }

    func testLegacyIngredientsPropertyIsAccepted() {
        let html = """
        <script type="application/ld+json">{"@type":"Recipe","ingredients":["2 cups flour"]}</script>
        """
        XCTAssertEqual(RecipeHTMLExtractor.extract(from: html)?.ingredientLines, ["2 cups flour"])
    }

    func testTypeVariantsAllCountAsRecipe() {
        XCTAssertTrue(RecipeHTMLExtractor.isRecipeType("Recipe"))
        XCTAssertTrue(RecipeHTMLExtractor.isRecipeType("schema:Recipe"))
        XCTAssertTrue(RecipeHTMLExtractor.isRecipeType("http://schema.org/Recipe"))
        XCTAssertTrue(RecipeHTMLExtractor.isRecipeType(["NewsArticle", "Recipe"]))
        XCTAssertFalse(RecipeHTMLExtractor.isRecipeType("RecipeCollection"))
        XCTAssertFalse(RecipeHTMLExtractor.isRecipeType("BlogPosting"))
        XCTAssertFalse(RecipeHTMLExtractor.isRecipeType(nil))
    }

    func testNestedRecipeUnderAnArbitraryWrapperIsFound() {
        let html = """
        <script type="application/ld+json">
        {"@context":"https://schema.org","mainEntity":{"@type":"Recipe","recipeIngredient":["1 lemon"]}}
        </script>
        """
        XCTAssertEqual(RecipeHTMLExtractor.extract(from: html)?.ingredientLines, ["1 lemon"])
    }

    // MARK: - Microdata

    func testMicrodataPage() throws {
        let extracted = try XCTUnwrap(RecipeHTMLExtractor.extract(from: fixture("microdata_only")))
        XCTAssertEqual(extracted.title, "Garlic & Herb Focaccia",
                       "itemprop=name beats the document title, which carries the site name too")
        XCTAssertEqual(extracted.servingsText, "One sheet pan", "a meta element's content attribute is its value")
        XCTAssertEqual(extracted.ingredientLines, [
            "4 cups bread flour",
            "2 ¼ teaspoons instant yeast",
            "2 teaspoons kosher salt",
            "½ cup olive oil, divided",
            "4 cloves garlic, thinly sliced",
            "2 sprigs rosemary",
        ])
    }

    func testMicrodataIsOnlyConsultedWhenJSONLDFindsNothing() {
        let html = """
        <script type="application/ld+json">{"@type":"Recipe","recipeIngredient":["from json-ld"]}</script>
        <li itemprop="recipeIngredient">from microdata</li>
        """
        XCTAssertEqual(RecipeHTMLExtractor.extract(from: html)?.ingredientLines, ["from json-ld"])
    }

    func testItemPropMatchIsWholeWordAndCaseInsensitive() {
        XCTAssertEqual(RecipeHTMLExtractor.itemPropValues("recipeIngredient",
                                                          in: "<li itemprop='recipeIngredients'>no</li>"),
                       [], "recipeIngredients is a different property")
        XCTAssertEqual(RecipeHTMLExtractor.itemPropValues("recipeIngredient",
                                                          in: "<li itemprop='RecipeIngredient'>yes</li>"),
                       ["yes"])
        XCTAssertEqual(RecipeHTMLExtractor.itemPropValues("recipeIngredient",
                                                          in: "<li itemprop='name recipeIngredient'>both</li>"),
                       ["both"], "a space-separated itemprop list counts")
        XCTAssertEqual(RecipeHTMLExtractor.itemPropValues("recipeIngredient",
                                                          in: "<li data-itemprop='recipeIngredient'>no</li>"),
                       [], "data-itemprop is not itemprop")
    }

    func testInnerTagsAreStrippedFromAnIngredientElement() {
        let html = "<li itemprop=\"recipeIngredient\">2 teaspoons <b>kosher</b> salt</li>"
        XCTAssertEqual(RecipeHTMLExtractor.itemPropValues("recipeIngredient", in: html),
                       ["2 teaspoons kosher salt"])
    }

    // MARK: - Tag scanner

    func testParseTagReadsNameAttributesAndSelfClosing() throws {
        let characters = Array("<meta itemprop=\"recipeYield\" content='Serves 4' hidden />")
        let tag = try XCTUnwrap(RecipeHTMLExtractor.parseTag(characters, from: 1, to: characters.count - 1))
        XCTAssertEqual(tag.name, "meta")
        XCTAssertEqual(tag.attribute("itemprop"), "recipeYield", "the value keeps its original case")
        XCTAssertEqual(tag.attribute("content"), "Serves 4")
        XCTAssertEqual(tag.attribute("hidden"), "", "a valueless attribute is present and empty")
        XCTAssertTrue(tag.isSelfClosing)
    }

    func testParseTagRejectsClosingTagsAndComments() {
        let close = Array("</div>")
        XCTAssertNil(RecipeHTMLExtractor.parseTag(close, from: 1, to: close.count - 1))
        let comment = Array("<!-- hi -->")
        XCTAssertNil(RecipeHTMLExtractor.parseTag(comment, from: 1, to: comment.count - 1))
    }

    func testParseTagAcceptsUnquotedValues() throws {
        let characters = Array("<li itemprop=recipeIngredient class=x>")
        let tag = try XCTUnwrap(RecipeHTMLExtractor.parseTag(characters, from: 1, to: characters.count - 1))
        XCTAssertEqual(tag.attribute("itemprop"), "recipeIngredient")
        XCTAssertEqual(tag.attribute("class"), "x")
    }

    func testDocumentTitle() {
        XCTAssertEqual(RecipeHTMLExtractor.documentTitle("<html><head><title>Soup &amp; Bread</title></head>"),
                       "Soup & Bread")
        XCTAssertNil(RecipeHTMLExtractor.documentTitle("<html><head></head></html>"))
    }

    func testCDATAUnwrappingKeepsJustTheJSON() {
        XCTAssertEqual(RecipeHTMLExtractor.unwrapCDATA("//<![CDATA[\n{\"a\":1}\n//]]>"), "{\"a\":1}")
        XCTAssertEqual(RecipeHTMLExtractor.unwrapCDATA("<![CDATA[{\"a\":1}]]>"), "{\"a\":1}")
        XCTAssertEqual(RecipeHTMLExtractor.unwrapCDATA("{\"a\":1}"), "{\"a\":1}", "no wrapper, no change")
    }
}
