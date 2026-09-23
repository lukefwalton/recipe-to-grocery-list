import XCTest
@testable import RecipeToGroceryList

/// §8 unit table: every spec spelling resolves to its key, `T`/`t` stay
/// case-sensitive, and `longestMatch` respects word boundaries so "large" never
/// reads as a liter.
final class UnitTableTests: XCTestCase {

    func testEverySpecRowResolves() {
        let rows: [(key: String, spellings: [String])] = [
            ("tsp", ["tsp", "teaspoon", "teaspoons", "t"]),
            ("tbsp", ["tbsp", "tablespoon", "tablespoons", "T", "tbs"]),
            ("cup", ["cup", "cups", "c"]),
            ("oz", ["oz", "ounce", "ounces"]),
            ("lb", ["lb", "lbs", "pound", "pounds"]),
            ("g", ["g", "gram", "grams"]),
            ("kg", ["kg", "kilogram", "kilograms"]),
            ("ml", ["ml", "milliliter", "milliliters", "millilitre", "millilitres"]),
            ("l", ["l", "liter", "liters", "litre", "litres"]),
            ("clove", ["clove", "cloves"]),
            ("can", ["can", "cans", "tin", "tins"]),
            ("bunch", ["bunch", "bunches"]),
            ("pinch", ["pinch", "pinches"]),
            ("piece", ["piece", "pieces", "whole"]),
            ("slice", ["slice", "slices"]),
            ("stick", ["stick", "sticks"]),
            ("head", ["head", "heads"]),
            ("sprig", ["sprig", "sprigs"]),
            ("package", ["package", "packages", "pkg", "packet", "packets"]),
        ]
        for row in rows {
            XCTAssertTrue(UnitTable.isKnownKey(row.key), row.key)
            for spelling in row.spellings {
                XCTAssertEqual(UnitTable.key(forSpelling: spelling), row.key, spelling)
                XCTAssertTrue(UnitTable.isSpelling(spelling), spelling)
            }
        }
    }

    func testCorpusAdditionsResolve() {
        XCTAssertEqual(UnitTable.key(forSpelling: "fl oz"), "floz")
        XCTAssertEqual(UnitTable.key(forSpelling: "fl. oz"), "floz")
        XCTAssertEqual(UnitTable.key(forSpelling: "qt"), "quart")
        XCTAssertEqual(UnitTable.key(forSpelling: "pt"), "pint")
        XCTAssertEqual(UnitTable.key(forSpelling: "gal"), "gallon")
        XCTAssertEqual(UnitTable.key(forSpelling: "rib"), "stalk")
        XCTAssertEqual(UnitTable.key(forSpelling: "handful"), "handful")
        XCTAssertEqual(UnitTable.key(forSpelling: "dash"), "dash")
    }

    func testSingleLetterTablespoonAndTeaspoonAreCaseSensitive() {
        XCTAssertEqual(UnitTable.key(forSpelling: "T"), "tbsp")
        XCTAssertEqual(UnitTable.key(forSpelling: "t"), "tsp")
        XCTAssertEqual(UnitTable.key(forSpelling: "T."), "tbsp")
    }

    func testMultiLetterSpellingsIgnoreCaseAndTrailingPeriods() {
        XCTAssertEqual(UnitTable.key(forSpelling: "Tbsp"), "tbsp")
        XCTAssertEqual(UnitTable.key(forSpelling: "TSP"), "tsp")
        XCTAssertEqual(UnitTable.key(forSpelling: "Cups"), "cup")
        XCTAssertEqual(UnitTable.key(forSpelling: "tsp."), "tsp")
        XCTAssertEqual(UnitTable.key(forSpelling: "oz.."), "oz")
        XCTAssertEqual(UnitTable.key(forSpelling: " lb "), "lb")
    }

    func testUnknownSpellingsResolveToNil() {
        XCTAssertNil(UnitTable.key(forSpelling: ""))
        XCTAssertNil(UnitTable.key(forSpelling: "."))
        XCTAssertNil(UnitTable.key(forSpelling: "large"))
        XCTAssertNil(UnitTable.key(forSpelling: "of"))
        XCTAssertNil(UnitTable.key(forSpelling: "onion"))
        XCTAssertFalse(UnitTable.isSpelling("eggs"))
        XCTAssertFalse(UnitTable.isKnownKey("cups"), "keys are the normalized form, not spellings")
    }

    func testKeysAreUniqueAndEverySpellingHasOneOwner() {
        XCTAssertEqual(Set(UnitTable.keys).count, UnitTable.keys.count)
        var owners: [String: String] = [:]
        for unit in UnitTable.all {
            for spelling in unit.spellings {
                let lowered = spelling.lowercased()
                XCTAssertNil(owners[lowered], "\(spelling) is claimed by \(owners[lowered] ?? "") and \(unit.key)")
                owners[lowered] = unit.key
            }
            for spelling in unit.caseSensitiveSpellings {
                XCTAssertEqual(spelling.count, 1, "case-sensitive spellings are single letters")
            }
        }
    }

    // MARK: - longestMatch

    private func match(_ text: String) -> (key: String, matchedText: String)? {
        UnitTable.longestMatch(atStartOf: Substring(text))
    }

    func testLongestMatchPrefersTheLongestSpelling() {
        XCTAssertEqual(match("cups flour")?.key, "cup")
        XCTAssertEqual(match("cups flour")?.matchedText, "cups")
        XCTAssertEqual(match("fl oz milk")?.key, "floz")
        XCTAssertEqual(match("fl oz milk")?.matchedText, "fl oz")
        XCTAssertEqual(match("tablespoons butter")?.matchedText, "tablespoons")
    }

    func testLongestMatchRequiresAWordBoundary() {
        XCTAssertNil(match("large eggs"), "'l' must not match inside 'large'")
        XCTAssertNil(match("Tomatoes"), "'T' must not match inside 'Tomatoes'")
        XCTAssertNil(match("cupsful"))
        XCTAssertEqual(match("l water")?.key, "l")
        XCTAssertEqual(match("tsp. salt")?.key, "tsp")
        XCTAssertEqual(match("cup, sifted")?.key, "cup")
        XCTAssertEqual(match("oz) can")?.key, "oz")
        XCTAssertEqual(match("cup")?.key, "cup", "end of text is a boundary")
    }

    func testLongestMatchKeepsTheAuthorsSpellingAndCase() {
        XCTAssertEqual(match("Tbsp. oil")?.matchedText, "Tbsp")
        XCTAssertEqual(match("Tbsp. oil")?.key, "tbsp")
        XCTAssertEqual(match("T soy sauce")?.key, "tbsp")
        XCTAssertEqual(match("t vanilla")?.key, "tsp")
        XCTAssertEqual(match("C flour")?.key, "cup")
        XCTAssertEqual(match("L milk")?.key, "l")
    }

    func testLongestMatchSkipsLeadingSpacesAndRejectsEmpty() {
        XCTAssertEqual(match("   cup sugar")?.key, "cup")
        XCTAssertNil(match(""))
        XCTAssertNil(match("   "))
    }

    // MARK: - Display

    func testDisplayNames() {
        XCTAssertEqual(UnitTable.displayName(forKey: "cup", quantity: 1), "cup")
        XCTAssertEqual(UnitTable.displayName(forKey: "cup", quantity: 2), "cups")
        XCTAssertEqual(UnitTable.displayName(forKey: "cup", quantity: 0.5), "cups")
        XCTAssertEqual(UnitTable.displayName(forKey: "cup", quantity: nil), "cup")
        XCTAssertEqual(UnitTable.displayName(forKey: "tsp", quantity: 3), "tsp", "abbreviations do not pluralize")
        XCTAssertEqual(UnitTable.displayName(forKey: "floz", quantity: 2), "fl oz")
        XCTAssertEqual(UnitTable.displayName(forKey: "zzz", quantity: 2), "zzz", "unknown keys fall back to the key")
    }

    func testDefinitionDisplayNameToleratesFloatingPointOne() {
        let cup = UnitTable.definition(forKey: "cup")
        XCTAssertEqual(cup?.displayName(for: 1.00001), "cup")
        XCTAssertEqual(cup?.displayName(for: 1.01), "cups")
    }
}
