import XCTest
@testable import RecipeToGroceryList

/// §7.1 normalization — the alias table's PRIMARY KEY *and* the input to every
/// matching layer, so these are the rules `scripts/ingredient_normalize.py` mirrors.
/// Expected values were cross-checked with a Python port before being asserted.
final class IngredientNormalizerTests: XCTestCase {

    // MARK: - normalize

    func testLowercasesCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(IngredientNormalizer.normalize("  Kosher   Salt "), "kosher salt")
        XCTAssertEqual(IngredientNormalizer.normalize("Bell\tPepper\n"), "bell pepper")
    }

    func testStripsDiacritics() {
        XCTAssertEqual(IngredientNormalizer.normalize("Crème fraîche"), "creme fraiche")
        XCTAssertEqual(IngredientNormalizer.normalize("Jalapeños"), "jalapeno")
    }

    func testDropsParentheticalsAndTrailingPunctuation() {
        XCTAssertEqual(IngredientNormalizer.normalize("(fresh) Jalapeños"), "jalapeno")
        XCTAssertEqual(IngredientNormalizer.normalize("onion,"), "onion")
        XCTAssertEqual(IngredientNormalizer.normalize("*salt*"), "salt")
        XCTAssertEqual(IngredientNormalizer.normalize("half-and-half"), "half-and-half", "interior punctuation survives")
    }

    func testRemovesLeadingArticleOnlyWhenSomethingFollows() {
        XCTAssertEqual(IngredientNormalizer.normalize("the onions,"), "onion")
        XCTAssertEqual(IngredientNormalizer.normalize("An Egg"), "egg")
        XCTAssertEqual(IngredientNormalizer.normalize("a pinch"), "pinch")
        XCTAssertEqual(IngredientNormalizer.normalize("a"), "a", "a lone article is kept")
    }

    func testSingularizesOnlyTheLastWord() {
        XCTAssertEqual(IngredientNormalizer.normalize("Tomatoes"), "tomato")
        XCTAssertEqual(IngredientNormalizer.normalize("green onions"), "green onion")
        XCTAssertEqual(IngredientNormalizer.normalize("Brussels sprouts"), "brussels sprout")
        XCTAssertEqual(IngredientNormalizer.normalize("Chick peas"), "chick pea")
        XCTAssertEqual(IngredientNormalizer.normalize("hummus"), "hummus")
        XCTAssertEqual(IngredientNormalizer.normalize("molasses"), "molasses")
    }

    func testNFKCFoldsCompatibilityForms() {
        // "½" folds to "1⁄2" under NFKC; the point is that both spellings meet.
        XCTAssertEqual(IngredientNormalizer.normalize("½ cup"), IngredientNormalizer.normalize("1⁄2 cup"))
    }

    func testEmptyAndPunctuationOnlyInputNormalizeToEmpty() {
        XCTAssertEqual(IngredientNormalizer.normalize(""), "")
        XCTAssertEqual(IngredientNormalizer.normalize("   "), "")
        XCTAssertEqual(IngredientNormalizer.normalize("(only a note)"), "")
        XCTAssertEqual(IngredientNormalizer.normalize("..."), "")
    }

    func testNormalizeIsIdempotent() {
        for raw in ["Tomatoes", "the Green Onions", "Crème fraîche (fresh)", "berries", "glasses", "peaches"] {
            let once = IngredientNormalizer.normalize(raw)
            XCTAssertEqual(IngredientNormalizer.normalize(once), once, raw)
        }
    }

    // MARK: - singularize

    func testSingularizeRules() {
        XCTAssertEqual(IngredientNormalizer.singularize("tomatoes"), "tomato")
        XCTAssertEqual(IngredientNormalizer.singularize("peaches"), "peach")
        XCTAssertEqual(IngredientNormalizer.singularize("radishes"), "radish")
        XCTAssertEqual(IngredientNormalizer.singularize("boxes"), "box")
        XCTAssertEqual(IngredientNormalizer.singularize("berries"), "berry")
        XCTAssertEqual(IngredientNormalizer.singularize("onions"), "onion")
        XCTAssertEqual(IngredientNormalizer.singularize("peas"), "pea")
        XCTAssertEqual(IngredientNormalizer.singularize("pies"), "pie", "'ies' rule needs more than 4 letters; falls back to dropping the s")
    }

    func testSingularizeLeavesShortWordsMassNounsAndExceptionsAlone() {
        XCTAssertEqual(IngredientNormalizer.singularize("gas"), "gas", "3 letters or fewer are never plurals")
        XCTAssertEqual(IngredientNormalizer.singularize("hummus"), "hummus")
        XCTAssertEqual(IngredientNormalizer.singularize("asparagus"), "asparagus")
        XCTAssertEqual(IngredientNormalizer.singularize("bass"), "bass")
        XCTAssertEqual(IngredientNormalizer.singularize("oats"), "oats")
        XCTAssertEqual(IngredientNormalizer.singularize("chips"), "chips")
        XCTAssertEqual(IngredientNormalizer.singularize("Swiss"), "Swiss", "case-sensitive exception list, capitalised input keeps its s via the -ss rule")
    }

    func testSingularizeSkipsWordsWithNonLetters() {
        // Documented current behaviour: a hyphenated last word is not singularized, so
        // "chick-peas" stays as is (the loose key still joins "chick peas"/"chickpeas").
        XCTAssertEqual(IngredientNormalizer.singularize("chick-peas"), "chick-peas")
        XCTAssertEqual(IngredientNormalizer.singularize("m&ms"), "m&ms")
    }

    // MARK: - looseKey

    func testLooseKeyJoinsSpacingAndPluralVariants() {
        XCTAssertEqual(IngredientNormalizer.looseKey("chick peas"), "chickpea")
        XCTAssertEqual(IngredientNormalizer.looseKey("Chickpea"), "chickpea")
        XCTAssertEqual(IngredientNormalizer.looseKey("chickpeas"), "chickpea")
        XCTAssertEqual(IngredientNormalizer.looseKey("Green-onion"), "greenonion")
        XCTAssertEqual(IngredientNormalizer.looseKey("green onion"), "greenonion")
        XCTAssertEqual(IngredientNormalizer.looseKey("Bell Pepper"), "bellpepper")
        XCTAssertEqual(IngredientNormalizer.looseKey("(x)"), "")
    }

    func testLooseKeyDoesNotJoinDifferentIngredients() {
        XCTAssertNotEqual(IngredientNormalizer.looseKey("smoked paprika"), IngredientNormalizer.looseKey("paprika"))
        XCTAssertNotEqual(IngredientNormalizer.looseKey("brown sugar"), IngredientNormalizer.looseKey("sugar"))
    }

    // MARK: - slugify

    func testSlugify() {
        XCTAssertEqual(IngredientNormalizer.slugify("Crème Fraîche"), "creme_fraiche")
        XCTAssertEqual(IngredientNormalizer.slugify("Half-and-half"), "half_and_half")
        XCTAssertEqual(IngredientNormalizer.slugify("Ben's Beans"), "bens_beans")
        XCTAssertEqual(IngredientNormalizer.slugify("  Olive  Oil "), "olive_oil")
        XCTAssertEqual(IngredientNormalizer.slugify(""), "")
        XCTAssertEqual(IngredientNormalizer.slugify("***"), "")
    }

    // MARK: - Pieces

    func testRemovingParentheticals() {
        XCTAssertEqual(IngredientNormalizer.removingParentheticals("a (b (c)) d"), "a  d")
        XCTAssertEqual(IngredientNormalizer.removingParentheticals("a (b"), "a ", "unbalanced opener runs to the end")
        XCTAssertEqual(IngredientNormalizer.removingParentheticals("a) b"), "a b", "a stray closer is dropped like any paren")
        XCTAssertEqual(IngredientNormalizer.removingParentheticals("plain"), "plain")
    }

    func testTrimmingPunctuation() {
        XCTAssertEqual(IngredientNormalizer.trimmingPunctuation("onion,"), "onion")
        XCTAssertEqual(IngredientNormalizer.trimmingPunctuation("*salt*"), "salt")
        XCTAssertEqual(IngredientNormalizer.trimmingPunctuation("half-and-half"), "half-and-half")
        XCTAssertEqual(IngredientNormalizer.trimmingPunctuation("..."), "")
        XCTAssertEqual(IngredientNormalizer.trimmingPunctuation("\"quoted\""), "quoted")
        XCTAssertEqual(IngredientNormalizer.trimmingPunctuation("$5"), "5", "symbols count as punctuation")
    }
}
