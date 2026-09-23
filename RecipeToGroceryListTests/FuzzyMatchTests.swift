import XCTest
@testable import RecipeToGroceryList

/// Layer 2's metric (§7.4). Every number below was computed with a line-for-line
/// Python port of `Normalize.swift` + `FuzzyMatch.swift` before it was asserted
/// (`scripts/reference_parser.py`, which the golden corpus also runs on), so these
/// are real values of the shipped metric, not hopes. `threshold` is
/// `IngredientResolver.defaultFuzzyThreshold`, calibrated to 0.86 on the corpus
/// (`docs/learnings/003-fuzzy-thresholds.md`).
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

        // "chicken" vs "chicken broth": the token metric halves it, and the head
        // nouns ("chicken" / "broth") share nothing, so the cap takes it to zero.
        XCTAssertEqual(FuzzyMatch.similarity("chicken", "Chicken broth"), 0, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("Chicken Broth", "Chicken"), threshold, "and from the other side")

        XCTAssertEqual(FuzzyMatch.similarity("garlic", "Garlic powder"), 0, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("garlic clove", "Garlic"), 0.4556, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("red onion", "Onion"), 0.5, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("green onions", "Onion"), 0.7333, accuracy: 0.001)
        for pair in [("garlic clove", "Garlic"), ("red onion", "Onion"), ("green onions", "Onion")] {
            XCTAssertLessThan(FuzzyMatch.similarity(pair.0, pair.1), threshold)
        }
    }

    func testModifiersThatChangeIdentityStayBelowThreshold() {
        XCTAssertEqual(FuzzyMatch.similarity("smoked paprika", "Paprika"), 0.7183, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("smoked paprika", "Paprika"), threshold)
        XCTAssertEqual(FuzzyMatch.similarity("brown sugar", "Sugar"), 0.5, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("brown sugar", "Sugar"), threshold)
        XCTAssertLessThan(FuzzyMatch.similarity("cilantro", "Coriander"), threshold, "different words, an alias's job")
    }

    /// The head-noun cap (§7.4): a shared *modifier* must not carry a match. Both
    /// of these scored high enough to resolve before the cap existed — the golden
    /// corpus is what surfaced them.
    func testASharedModifierDoesNotCarryAMatch() {
        XCTAssertEqual(FuzzyMatch.similarity("grated gruyere", "grated nutmeg"), 0.5397, accuracy: 0.001,
                       "was 0.8667 before the cap, and resolved Gruyère to Nutmeg")
        XCTAssertEqual(FuzzyMatch.similarity("shredded carot", "shredded cheddar"), 0.5029, accuracy: 0.001,
                       "was 0.9214, and resolved a carrot to cheddar")
        XCTAssertEqual(FuzzyMatch.similarity("baking soda", "Baking powder"), 0.6111, accuracy: 0.001,
                       "was 0.9021 — two genuinely different leaveners")
        for pair in [("grated gruyere", "grated nutmeg"), ("shredded carot", "shredded cheddar"),
                     ("baking soda", "Baking powder")] {
            XCTAssertLessThan(FuzzyMatch.similarity(pair.0, pair.1), threshold)
        }
    }

    // MARK: - similarity: real variants clear the threshold

    func testPluralsAndCasingAreNotDifferences() {
        XCTAssertEqual(FuzzyMatch.similarity("tomatos", "Tomato"), 1, "normalizes to the same word")
        XCTAssertEqual(FuzzyMatch.similarity("scallions", "Scallion"), 1)
        XCTAssertEqual(FuzzyMatch.similarity("all purpose flour", "All-purpose flour"), 1)
    }

    func testTyposAndShorthandClearTheThreshold() {
        XCTAssertEqual(FuzzyMatch.similarity("veggie broth", "Vegetable broth"), 0.8963, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("bell peper", "Bell pepper"), 0.9611, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("mozzarela", "Mozzarella"), 0.98, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("chiken", "Chicken"), 0.9667, accuracy: 0.001)
        XCTAssertEqual(FuzzyMatch.similarity("greek yoghurt", "Greek yogurt"), 0.9667, accuracy: 0.001)
        for pair in [("veggie broth", "Vegetable broth"), ("veggie stock", "Vegetable stock"),
                     ("bell peper", "Bell pepper"), ("mozzarela", "Mozzarella"),
                     ("chiken", "Chicken"), ("greek yoghurt", "Greek yogurt")] {
            XCTAssertGreaterThanOrEqual(FuzzyMatch.similarity(pair.0, pair.1), threshold, "\(pair.0) / \(pair.1)")
        }
    }

    func testGarbageScoresLow() {
        XCTAssertEqual(FuzzyMatch.similarity("asdfqwer", "Bell pepper"), 0.2639, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("qwertyuiop", "Olive oil"), 0.6)
    }

    func testWholeStringScoreOnlyAppliesToSameWordCount() {
        // Same word count and agreeing heads: the whole-string Jaro–Winkler can
        // lift the score above the token metric… up to the head-noun cap.
        XCTAssertEqual(FuzzyMatch.similarity("bell peper", "Bell pepper"),
                       FuzzyMatch.jaroWinkler("peper", "pepper"), accuracy: 1e-9,
                       "capped by the heads, which is still comfortably over the threshold")
        // Different word counts: the whole-string score never applies at all.
        XCTAssertLessThanOrEqual(FuzzyMatch.similarity("chicken", "Chicken broth"),
                                 FuzzyMatch.tokenSimilarity("chicken", "chicken broth"))
    }

    func testSimilarityIsSymmetricAndEmptySafe() {
        for (a, b) in [("veggie broth", "Vegetable broth"), ("chicken", "Chicken broth"), ("mozzarela", "Mozzarella")] {
            XCTAssertEqual(FuzzyMatch.similarity(a, b), FuzzyMatch.similarity(b, a), accuracy: 1e-9, "\(a) / \(b)")
        }
        XCTAssertEqual(FuzzyMatch.similarity("", "Onion"), 0)
        XCTAssertEqual(FuzzyMatch.similarity("   ", "Onion"), 0)
        XCTAssertEqual(FuzzyMatch.similarity("(note only)", "Onion"), 0, "normalizes to empty")
    }

    /// The trap the metric still doesn't catch on its own, recorded so it stays
    /// known: a two-word query whose head noun *is* the candidate scores 0.5 plus
    /// half the head's own similarity. "Ice cream" clears that only because 0.844
    /// now sits below the calibrated threshold — and the seed also carries it as
    /// its own canonical, so an exact hit never reaches layer 2.
    func testKnownRemainingTrapIsDocumented() {
        XCTAssertEqual(FuzzyMatch.similarity("ice cream", "Cream"), 0.8444, accuracy: 0.001)
        XCTAssertLessThan(FuzzyMatch.similarity("ice cream", "Cream"), threshold,
                          "below 0.86; it would have matched at the workout app's 0.78")
    }
}
