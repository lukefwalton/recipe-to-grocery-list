import XCTest
@testable import RecipeToGroceryList

/// §11 golden corpus: `Fixtures/ingredient_lines.json` (a few hundred real-world
/// shaped lines with expected quantity / unit_key / name / note / slug) scored
/// against the splitter (§7.2) and layers 0–2 of resolution (§7.4) over the real
/// seed. Both pass rates are printed with a `[GoldenCorpus]` prefix and must never
/// drop below the `baseline` stored in the fixture — this is how thresholds get
/// calibrated (§13), and any regression fails the build.
final class GoldenCorpusTests: XCTestCase {

    private struct Fixture: Decodable {
        struct Baseline: Decodable {
            let splitter: Double
            let resolution: Double
        }

        struct Line: Decodable {
            let line: String
            let quantity: Double?
            let unitKey: String?
            let name: String?
            let note: String?
            let slug: String?
            let source: String?

            enum CodingKeys: String, CodingKey {
                case line, quantity, name, note, slug, source
                case unitKey = "unit_key"
            }
        }

        let baseline: Baseline
        let lines: [Line]
    }

    private static let minimumLines = 200
    private static let reportedMismatches = 25

    // MARK: - Loading

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ingredient_lines", withExtension: "json"),
                                "Fixtures/ingredient_lines.json must be bundled flat with the test target")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    /// The real seed as an in-memory index with synthetic ids, aliases normalized
    /// exactly as `seedIngredientsIfNeeded` stores them, plus id → slug for scoring.
    private func makeSeedIndex() throws -> (index: IngredientIndex, slugByID: [Int64: String]) {
        let seeds = try IngredientSeed.load(from: Bundle(for: Self.self))
        var entries: [IngredientIndexEntry] = []
        var slugs: [Int64: String] = [:]
        for (offset, seed) in seeds.enumerated() {
            let id = Int64(offset + 1)
            entries.append(IngredientIndexEntry(id: id,
                                                canonicalName: seed.canonicalName,
                                                category: seed.category,
                                                aliases: seed.aliases.map(IngredientNormalizer.normalize)))
            slugs[id] = seed.slug
        }
        return (IngredientIndex(entries: entries), slugs)
    }

    // MARK: - Comparison

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    private static func sameOptionalText(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return collapsed(a) == collapsed(b)
        default: return false
        }
    }

    private static func sameQuantity(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a - b) <= 1e-6
        default: return false
        }
    }

    /// Splitter agreement: quantity within 1e-6, same unit key, name equal
    /// case-insensitively after whitespace collapse, note likewise.
    private static func splitterMatches(_ actual: StructuredLine, _ expected: Fixture.Line) -> Bool {
        sameQuantity(actual.quantity, expected.quantity)
            && actual.unitKey == expected.unitKey
            && collapsed(actual.name) == collapsed(expected.name ?? expected.line)
            && sameOptionalText(actual.note, expected.note)
    }

    /// Baselines may be stored as fractions (0.93) or percentages (93).
    private static func fraction(_ value: Double) -> Double {
        value > 1 ? value / 100 : value
    }

    private static func percent(_ rate: Double) -> String {
        String(format: "%.1f%%", rate * 100)
    }

    // MARK: - Tests

    func testCorpusIsLargeEnoughToCalibrateOn() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.lines.count, Self.minimumLines,
                                    "§11 asks for a few hundred lines; thresholds calibrated on fewer are noise")
        XCTAssertTrue(fixture.lines.allSatisfy { !$0.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                      "every corpus entry has a line")
        for line in fixture.lines {
            if let key = line.unitKey {
                XCTAssertTrue(UnitTable.isKnownKey(key), "unknown unit_key \(key) in \(line.line.debugDescription)")
            }
        }
    }

    func testExpectedSlugsExistInTheSeed() throws {
        let fixture = try loadFixture()
        let seeds = try IngredientSeed.load(from: Bundle(for: Self.self))
        let seedSlugs = Set(seeds.map(\.slug))
        let expected = Set(fixture.lines.compactMap(\.slug))
        let missing = expected.subtracting(seedSlugs).sorted()
        XCTAssertTrue(missing.isEmpty, "corpus expects slugs the seed does not have: \(missing)")
    }

    func testSplitterAndResolutionPassRatesNeverDropBelowBaseline() throws {
        let fixture = try loadFixture()
        let seed = try makeSeedIndex()
        // Layers 0–2 only: NoopEmbedding and no candidate set, so layer 3 is off (§7.6
        // is the path every device has).
        let resolver = IngredientResolver(index: seed.index)

        var splitterPasses = 0
        var resolutionPasses = 0
        var splitterMisses: [String] = []
        var resolutionMisses: [String] = []

        for expected in fixture.lines {
            let structured = IngredientLineSplitter.split(expected.line)
            if Self.splitterMatches(structured, expected) {
                splitterPasses += 1
            } else if splitterMisses.count < Self.reportedMismatches {
                splitterMisses.append(
                    "\(expected.line.debugDescription): got (\(structured.quantity.map { String($0) } ?? "nil"), "
                    + "\(structured.unitKey ?? "nil"), \(structured.name.debugDescription), \(structured.note?.debugDescription ?? "nil")) "
                    + "expected (\(expected.quantity.map { String($0) } ?? "nil"), \(expected.unitKey ?? "nil"), "
                    + "\((expected.name ?? expected.line).debugDescription), \(expected.note?.debugDescription ?? "nil"))")
            }

            let hit = resolver.resolve(structured.name).hit
            let actualSlug: String? = hit.flatMap { seed.slugByID[$0.ingredientID] }
            if actualSlug == expected.slug {
                resolutionPasses += 1
            } else if resolutionMisses.count < Self.reportedMismatches {
                let layer = hit.map { $0.resolution.rawValue } ?? "none"
                resolutionMisses.append(
                    "\(expected.line.debugDescription) → name \(structured.name.debugDescription): got \(actualSlug ?? "nil") "
                    + "via \(layer), expected \(expected.slug ?? "nil")")
            }
        }

        let total = Double(max(fixture.lines.count, 1))
        let splitterRate = Double(splitterPasses) / total
        let resolutionRate = Double(resolutionPasses) / total
        let splitterBaseline = Self.fraction(fixture.baseline.splitter)
        let resolutionBaseline = Self.fraction(fixture.baseline.resolution)

        print("[GoldenCorpus] splitter \(splitterPasses)/\(fixture.lines.count) = \(Self.percent(splitterRate)) (baseline \(Self.percent(splitterBaseline)))")
        print("[GoldenCorpus] resolution (layers 0–2) \(resolutionPasses)/\(fixture.lines.count) = \(Self.percent(resolutionRate)) (baseline \(Self.percent(resolutionBaseline)))")
        for miss in splitterMisses { print("[GoldenCorpus] splitter miss: \(miss)") }
        for miss in resolutionMisses { print("[GoldenCorpus] resolution miss: \(miss)") }

        XCTAssertGreaterThanOrEqual(splitterRate + 1e-9, splitterBaseline,
                                    "splitter pass rate dropped below the fixture baseline")
        XCTAssertGreaterThanOrEqual(resolutionRate + 1e-9, resolutionBaseline,
                                    "resolution pass rate dropped below the fixture baseline")
    }
}
