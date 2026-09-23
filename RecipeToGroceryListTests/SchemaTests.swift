import XCTest
@testable import RecipeToGroceryList

/// The migration contract (spec §3, §6): a fresh install lays down v1 in one
/// transaction and stamps `user_version 1`; running `migrate()` again on a v1
/// database is a no-op that touches neither the stamp nor the data.
final class SchemaTests: XCTestCase {

    private var path: String!
    private var db: SQLiteDB!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "rtg-schema-\(UUID().uuidString).sqlite"
        db = try SQLiteDB(path: path)   // NOT migrated: the migration is what's under test
    }

    override func tearDownWithError() throws {
        db = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    private func names(ofType type: String) throws -> [String] {
        let stmt = try db.prepare("SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        defer { stmt.finalize() }
        stmt.bind(text: type, at: 1)
        var found: [String] = []
        while try stmt.step() {
            if let name = stmt.text(0) { found.append(name) }
        }
        return found
    }

    func testLatestVersionIsOneAtV1Ship() {
        XCTAssertEqual(Schema.latestVersion, 1)
    }

    func testFreshInstallLaysDownV1AndStampsVersionOne() throws {
        XCTAssertEqual(try db.userVersion(), 0, "a new file starts unstamped")
        try Schema.migrate(db)
        XCTAssertEqual(try db.userVersion(), 1)
        XCTAssertEqual(try names(ofType: "table"),
                       ["check_state", "ingredient_aliases", "ingredients", "manual_items", "recipe_ingredients", "recipes"],
                       "exactly the six SPEC §6 tables")
    }

    func testFreshInstallCreatesTheLookupIndexes() throws {
        try Schema.migrate(db)
        let indexes = try names(ofType: "index").filter { $0.hasPrefix("idx_") }
        XCTAssertEqual(indexes, [
            "idx_ingredient_aliases_ingredient",
            "idx_ingredients_category",
            "idx_recipe_ingredients_ingredient",
            "idx_recipe_ingredients_recipe",
            "idx_recipes_selected",
        ])
    }

    func testSecondMigrateOnV1DatabaseIsANoOp() throws {
        try Schema.migrate(db)
        try db.execute("INSERT INTO ingredients (slug, canonical_name, created_at) VALUES ('garlic', 'Garlic', 't');")
        try db.execute("INSERT INTO manual_items (text, created_at) VALUES ('coffee', 't');")
        let tablesBefore = try names(ofType: "table")

        try Schema.migrate(db)
        try Schema.migrate(db)

        XCTAssertEqual(try db.userVersion(), 1, "still stamped 1")
        XCTAssertEqual(try names(ofType: "table"), tablesBefore, "no table added, dropped or renamed")
        let stmt = try db.prepare("SELECT (SELECT COUNT(*) FROM ingredients), (SELECT COUNT(*) FROM manual_items);")
        defer { stmt.finalize() }
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.int(0), 1, "data survives a re-run")
        XCTAssertEqual(stmt.int(1), 1)
    }

    func testMigrationLeavesNoOpenTransaction() throws {
        try Schema.migrate(db)
        // If migrate() had left a transaction open, this BEGIN would fail.
        try db.transaction {
            try db.execute("INSERT INTO manual_items (text, created_at) VALUES ('coffee', 't');")
        }
        let stmt = try db.prepare("SELECT COUNT(*) FROM manual_items;")
        defer { stmt.finalize() }
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.int(0), 1)
    }
}
