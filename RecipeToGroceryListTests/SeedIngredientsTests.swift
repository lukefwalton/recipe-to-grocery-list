import XCTest
@testable import RecipeToGroceryList

/// Invariants of the bundled ingredient library (spec §3 "seed invariant tests",
/// §6). `scripts/build_seed.py` checks the same rules at build time with a Python
/// mirror of the normalizer; these re-check them at runtime with the REAL
/// `IngredientNormalizer`, so drift between the two shows up as a failing test
/// rather than a silently dropped alias at seed time. Ported from `workout-logger`
/// `WorkoutChatLogTests/SeedExercisesTests.swift` (@5bffddfb80fc).
final class SeedIngredientsTests: XCTestCase {

    private func loadSeeds() throws -> [SeedIngredient] {
        try IngredientSeed.load(from: Bundle(for: Self.self))
    }

    private func rawJSON() throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "seed_ingredients", withExtension: "json"),
                                "seed_ingredients.json must be bundled with the test target")
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [[String: Any]], "the seed is a JSON array of objects")
    }

    func testSeedLoadsAtLeastTwoHundredFiftyIngredients() throws {
        XCTAssertGreaterThanOrEqual(try loadSeeds().count, 250, "spec §6: a few hundred common items")
    }

    func testSeedVersionIsSet() {
        XCTAssertFalse(IngredientSeed.version.isEmpty)
    }

    func testEverySeedHasASlugAndACanonicalName() throws {
        for seed in try loadSeeds() {
            XCTAssertFalse(seed.slug.trimmingCharacters(in: .whitespaces).isEmpty, "\(seed.canonicalName) is missing a slug")
            XCTAssertFalse(seed.canonicalName.trimmingCharacters(in: .whitespaces).isEmpty, "\(seed.slug) is missing a canonical name")
            XCTAssertEqual(seed.canonicalName, seed.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines),
                           "\(seed.slug): canonical name has stray whitespace")
        }
    }

    func testSlugsAreUnique() throws {
        let slugs = try loadSeeds().map(\.slug)
        XCTAssertEqual(Set(slugs).count, slugs.count, "slugs must be unique — they are the upsert key")
    }

    /// A custom ingredient created in Confirm gets `IngredientNormalizer.slugify(name)`;
    /// the seed must author slugs the same way so a custom that later ships as a
    /// seed entry lines up on the same key instead of duplicating it.
    func testEverySlugIsTheSlugifiedCanonicalName() throws {
        for seed in try loadSeeds() {
            XCTAssertEqual(seed.slug, IngredientNormalizer.slugify(seed.canonicalName),
                           "slug for \"\(seed.canonicalName)\" must be slugify(canonical_name)")
        }
    }

    func testCanonicalNamesAreUniqueUnderNormalization() throws {
        // Layer 0 matches canonical names case-insensitively and the alias key is
        // the normalized form, so two canonicals that normalize alike would resolve
        // nondeterministically ("Tomato" vs "tomatoes").
        var seen: [String: String] = [:]
        for seed in try loadSeeds() {
            let key = IngredientNormalizer.normalize(seed.canonicalName)
            XCTAssertFalse(key.isEmpty, "\"\(seed.canonicalName)\" normalizes to nothing")
            if let other = seen[key] {
                XCTFail("\"\(seed.canonicalName)\" and \"\(other)\" collide under normalize (\(key))")
            }
            seen[key] = seed.canonicalName
        }
    }

    func testAliasesAreGloballyUniqueUnderNormalization() throws {
        // The store keys ingredient_aliases on IngredientNormalizer.normalize and
        // inserts with OR IGNORE, so two seed aliases that normalize alike would
        // silently collide at seed time — one quietly dropped.
        var seen: [String: String] = [:]
        for seed in try loadSeeds() {
            for alias in seed.aliases {
                let key = IngredientNormalizer.normalize(alias)
                XCTAssertFalse(key.isEmpty, "alias \"\(alias)\" on \(seed.canonicalName) normalizes to nothing")
                if let owner = seen[key], owner != seed.slug {
                    XCTFail("alias \"\(alias)\" (\(key)) is claimed by both \(owner) and \(seed.slug)")
                }
                seen[key] = seed.slug
            }
        }
    }

    func testNoAliasCollidesWithAnotherCanonicalName() throws {
        // Resolution is exact-canonical → alias, so an alias equal to a *different*
        // item's canonical name would be shadowed by the exact match and silently
        // resolve to the wrong ingredient.
        let seeds = try loadSeeds()
        var canonicalBySlug: [String: String] = [:]
        var slugByCanonicalKey: [String: String] = [:]
        for seed in seeds {
            canonicalBySlug[seed.slug] = seed.canonicalName
            slugByCanonicalKey[IngredientNormalizer.normalize(seed.canonicalName)] = seed.slug
        }
        for seed in seeds {
            for alias in seed.aliases {
                let key = IngredientNormalizer.normalize(alias)
                if let otherSlug = slugByCanonicalKey[key], otherSlug != seed.slug {
                    XCTFail("alias \"\(alias)\" on \(seed.canonicalName) equals \(canonicalBySlug[otherSlug] ?? otherSlug)'s canonical name")
                }
            }
        }
    }

    func testEveryCategoryIsInTheClosedVocabulary() throws {
        // Decoding into `IngredientCategory` already refuses unknown strings; check
        // the raw file too so the failure names the offending entry.
        let allowed = Set(IngredientCategory.allCases.map(\.rawValue))
        for object in try rawJSON() {
            let category = object["category"] as? String ?? "<missing>"
            XCTAssertTrue(allowed.contains(category),
                          "\(object["slug"] ?? "?"): category \"\(category)\" is not one of \(allowed.sorted())")
        }
        // And the typed decode agrees on the count.
        XCTAssertEqual(try loadSeeds().count, try rawJSON().count)
    }

    func testSeedUsesSnakeCaseKeysOnly() throws {
        let expected: Set<String> = ["slug", "canonical_name", "category", "aliases"]
        for object in try rawJSON() {
            XCTAssertEqual(Set(object.keys), expected, "\(object["slug"] ?? "?") has unexpected keys")
        }
    }

    /// The examples the spec itself gives (§6) must be in the library, with the
    /// aliases pointing where it says.
    func testSpecExampleAliasesResolveToTheSpecCanonicals() throws {
        let seeds = try loadSeeds()
        var canonicalKeyByAliasKey: [String: String] = [:]
        for seed in seeds {
            let canonicalKey = IngredientNormalizer.normalize(seed.canonicalName)
            for alias in seed.aliases {
                canonicalKeyByAliasKey[IngredientNormalizer.normalize(alias)] = canonicalKey
            }
        }
        let expectations: [(alias: String, canonical: String)] = [
            ("veggie broth", "vegetable broth"),
            ("vegetable stock", "vegetable broth"),
            ("green onion", "scallion"),
            ("spring onion", "scallion"),
            ("coriander leaf", "cilantro"),
            ("fresh coriander", "cilantro"),
        ]
        for expectation in expectations {
            XCTAssertEqual(canonicalKeyByAliasKey[IngredientNormalizer.normalize(expectation.alias)],
                           IngredientNormalizer.normalize(expectation.canonical),
                           "spec §6 example: \"\(expectation.alias)\" → \(expectation.canonical)")
        }
    }
}
