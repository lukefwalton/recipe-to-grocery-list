import XCTest
@testable import RecipeToGroceryList

/// Layer 2's metric (§7.4). Every number below was computed with a line-for-line
/// Python port of `Normalize.swift` + `FuzzyMatch.swift` before it was asserted
/// (session scratchpad `fuzzy_check.py`), so the traps here are real values of the
/// shipped metric, not hopes. The 0.78 threshold is `IngredientResolver.defaultFuzzyThreshold`.
final class FuzzyMatchTests: XCTestCase {

    private let threshold = IngredientResolver.defaultFuzzyThreshold

    // MARK: - Jaro / Jaro–Winkler (published reference values)

    func testJaroReferenceValues() {
        XCTAssertEqual(FuzzyMatch.jaro("martha", "marhta"), 0.9444, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.jaro("dixon", "dicksonx"), 0.7667, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.jaro("abc", "abc"), 1)
        XCTAssertEqual(FuzzyMatch.jaro("abc", "xyz"), 0)
        XCTAssertEqual(FuzzyMatch.jaro("", ""), 0, "two empties are not a match")
        XCTAssertEqual(FuzzyMatch.jaro("", "abc"), 0)
    }

    func testJaroWinklerAddsThePrefixBonus() {
        XCTAssertEqual(FuzzyMatch.jaroWinkler("martha", "marhta"), 0.9611, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.jaroWinkler("dixon", "dicksonx"), 0.8133, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.jaroWinkler("tomatos", "tomato"), 0.9714, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.jaroWinkler("bench", "bench"), 1)
        XCTAssertEqual(FuzzyMatch.jaroWinkler("asdf", "bench"), 0)
    }

    // MARK: - Tokens

    func testTokensSplitOnAnythingThatIsNotALetterOrDigit() {
        XCTAssertEqual(FuzzyMatch.tokens("Bell-Pepper, red"), ["bell", "pepper", "red"])
        XCTAssertEqual(FuzzyMatch.tokens("  "), [])
        XCTAssertEqual(FuzzyMatch.tokens("2% milk"), ["2", "milk"])
    }

    func testTokenSimilarityIsSymmetricAndChargesForExtraWords() {
        XCTAssertEqual(FuzzyMatch.directedTokenSimilarity("cream", "sour cream"), 1.0, accuracy: 1e-9,
                       "the workout metric: a short query is fully contained")
        XCTAssertEqual(FuzzyMatch.directedTokenSimilarity("sour cream", "cream"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(FuzzyMatch.tokenSimilarity("cream", "sour cream"), 0.5, accuracy: 1e-9,
                       "the food metric takes the minimum of both directions")
        XCTAssertEqual(FuzzyMatch.tokenSimilarity("sour cream", "cream"), FuzzyMatch.tokenSimilarity("cream", "sour cream"))
        XCTAssertEqual(FuzzyMatch.tokenSimilarity("", "cream"), 0)
    }

    // MARK: - similarity: substring traps (§7.4) stay below the threshold

    func testSubstringTrapsStayBelowThreshold() {
        XCTAssertEqual(FuzzyMatch.similarity("cream", "Sour cream"), 0.5, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("cream", "Sour cream"), threshold)

        XCTAssertEqual(FuzzyMatch.similarity("chicken", "Chicken broth"), 0.5, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("chicken", "Chicken broth"), threshold)
        XCTAssertLessThan(FuzzyMatch.similarity("Chicken Broth", "Chicken"), threshold, "and from the other side")

        XCTAssertEqual(FuzzyMatch.similarity("garlic", "Garlic powder"), 0.5, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("garlic clove", "Garlic"), threshold)
        XCTAssertLessThan(FuzzyMatch.similarity("red onion", "Onion"), threshold)
        XCTAssertLessThan(FuzzyMatch.similarity("green onions", "Onion"), threshold)
    }

    func testModifiersThatChangeIdentityStayBelowThreshold() {
        XCTAssertEqual(FuzzyMatch.similarity("smoked paprika", "Paprika"), 0.7183, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("smoked paprika", "Paprika"), threshold)
        XCTAssertEqual(FuzzyMatch.similarity("brown sugar", "Sugar"), 0.5, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("brown sugar", "Sugar"), threshold)
        XCTAssertLessThan(FuzzyMatch.similarity("cilantro", "Coriander"), threshold, "different words, an alias's job")
    }

    // MARK: - similarity: real variants clear the threshold

    func testPluralsAndCasingAreNotDifferences() {
        XCTAssertEqual(FuzzyMatch.similarity("tomatos", "Tomato"), 1, "normalizes to the same word")
        XCTAssertEqual(FuzzyMatch.similarity("scallions", "Scallion"), 1)
        XCTAssertEqual(FuzzyMatch.similarity("all purpose flour", "All-purpose flour"), 1)
    }

    func testTyposAndShorthandClearTheThreshold() {
        XCTAssertEqual(FuzzyMatch.similarity("veggie broth", "Vegetable broth"), 0.8963, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(FuzzyMatch.similarity("veggie broth", "Vegetable broth"), threshold)
        XCTAssertGreaterThanOrEqual(FuzzyMatch.similarity("veggie stock", "Vegetable stock"), threshold)
        XCTAssertEqual(FuzzyMatch.similarity("bell peper", "Bell pepper"), 0.9818, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("mozzarela", "Mozzarella"), 0.98, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("chiken", "Chicken"), 0.9667, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(FuzzyMatch.similarity("greek yoghurt", "Greek yogurt"), threshold)
    }

    func testGarbageScoresLow() {
        XCTAssertEqual(FuzzyMatch.similarity("asdfqwer", "Bell pepper"), 0.2639, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("qwertyuiop", "Olive oil"), 0.6)
    }

    func testWholeStringScoreOnlyAppliesToSameWordCount() {
        // Same word count: the whole-string Jaro–Winkler may lift the score.
        XCTAssertGreaterThan(FuzzyMatch.similarity("bell peper", "Bell pepper"),
                             FuzzyMatch.tokenSimilarity("bell peper", "bell pepper"))
        // Different word counts: only the symmetric token metric decides.
        XCTAssertEqual(FuzzyMatch.similarity("chicken", "Chicken broth"),
                       FuzzyMatch.tokenSimilarity("chicken", "chicken broth"), accuracy: 1e-9)
    }

    func testSimilarityIsSymmetricAndEmptySafe() {
        for (a, b) in [("veggie broth", "Vegetable broth"), ("chicken", "Chicken broth"), ("mozzarela", "Mozzarella")] {
            XCTAssertEqual(FuzzyMatch.similarity(a, b), FuzzyMatch.similarity(b, a), accuracy: 1e-9, "\(a) / \(b)")
        }
        XCTAssertEqual(FuzzyMatch.similarity("", "Onion"), 0)
        XCTAssertEqual(FuzzyMatch.similarity("   ", "Onion"), 0)
        XCTAssertEqual(FuzzyMatch.similarity("(note only)", "Onion"), 0, "normalizes to empty")
    }

    /// A remaining trap the metric does *not* catch, recorded so calibration on the
    /// golden corpus (§11) sees it: a two-word query with one exact word scores at
    /// least 0.5 plus half the other word's similarity. The seed covers it by having
    /// "Ice cream" as its own canonical (an exact hit never reaches layer 2).
    func testKnownRemainingTrapIsDocumented() {
        XCTAssertEqual(FuzzyMatch.similarity("ice cream", "Cream"), 0.8444, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("baking soda", "Baking powder"), 0.9021, accuracy: 0.001)
    }
}
