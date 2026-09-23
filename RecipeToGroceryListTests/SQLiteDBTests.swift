import XCTest
@testable import RecipeToGroceryList

/// Low-level storage guarantees that protect the data contract: atomic
/// transactions, the FK cascades and SET NULL, the alias PRIMARY KEY, the CHECK
/// constraints on the closed vocabularies, and the reads-only snapshot. Exercised
/// against `SQLiteDB` + `Schema` directly — the right altitude, since these are
/// properties of the connection and the schema rather than of the domain store.
/// Ported from `workout-logger` `WorkoutChatLogTests/SQLiteDBTests.swift`
/// (@5bffddfb80fc) with the fixtures re-pointed at this schema.
final class SQLiteDBTests: XCTestCase {

    private var path: String!
    private var db: SQLiteDB!

    override func setUpWithError() throws {
        path = NSTemporaryDirectory() + "rtg-sqlite-\(UUID().uuidString).sqlite"
        db = try SQLiteDB(path: path)
        try Schema.migrate(db)
    }

    override func tearDownWithError() throws {
        db = nil   // close before deleting the file
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }
    }

    // MARK: - Raw fixtures (test-only; production SQL lives under Storage/)

    private func count(_ table: String) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { stmt.finalize() }
        return try stmt.step() ? Int(stmt.int(0)) : 0
    }

    private func insertIngredient(_ slug: String, _ name: String) throws {
        try db.execute("INSERT INTO ingredients (slug, canonical_name, created_at) VALUES ('\(slug)', '\(name)', 't');")
    }

    private func insertRecipe(_ title: String, selected: Bool = false) throws {
        try db.execute("""
            INSERT INTO recipes (title, source_kind, raw_lines, is_selected, created_at, updated_at)
            VALUES ('\(title)', 'text', '[]', \(selected ? 1 : 0), 't', 't');
        """)
    }

    private func insertRow(recipe: Int64, ingredient: Int64?, line: String) throws {
        let ingredientLiteral = ingredient.map { String($0) } ?? "NULL"
        try db.execute("""
            INSERT INTO recipe_ingredients (recipe_id, ingredient_id, raw_line, name, resolution, sort_order)
            VALUES (\(recipe), \(ingredientLiteral), '\(line)', '\(line)', 'exact', 0);
        """)
    }

    // MARK: - Migration

    func testMigrationStampsAndIsIdempotent() throws {
        XCTAssertEqual(try db.userVersion(), Schema.latestVersion)
        try Schema.migrate(db)   // second run is a no-op
        XCTAssertEqual(try db.userVersion(), Schema.latestVersion)
    }

    // MARK: - Schema constraints

    /// The closed vocabularies are CHECK constraints so the database — not just
    /// the save path — rejects bad data from any future writer.
    func testV1SchemaEnforcesConstraints() throws {
        try insertIngredient("garlic", "Garlic")
        try insertRecipe("Soup")
        try insertRow(recipe: 1, ingredient: 1, line: "2 cloves garlic")

        // Out-of-vocabulary category is rejected by CHECK.
        XCTAssertThrowsError(try db.execute(
            "INSERT INTO ingredients (slug, canonical_name, category, created_at) VALUES ('x', 'X', 'snacks', 't');"
        ))
        // Out-of-vocabulary source_kind is rejected by CHECK.
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO recipes (title, source_kind, raw_lines, created_at, updated_at)
            VALUES ('R', 'carrier_pigeon', '[]', 't', 't');
        """))
        // Out-of-vocabulary resolution is rejected by CHECK.
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO recipe_ingredients (recipe_id, ingredient_id, raw_line, name, resolution, sort_order)
            VALUES (1, 1, 'x', 'x', 'psychic', 1);
        """))
        // The slug is UNIQUE.
        XCTAssertThrowsError(try db.execute(
            "INSERT INTO ingredients (slug, canonical_name, created_at) VALUES ('garlic', 'Dup', 't');"
        ))
        // A recipe row must point at a real recipe.
        XCTAssertThrowsError(try db.execute("""
            INSERT INTO recipe_ingredients (recipe_id, ingredient_id, raw_line, name, resolution, sort_order)
            VALUES (999, NULL, 'x', 'x', 'none', 0);
        """))
        // Category defaults to 'other'.
        try insertIngredient("mystery", "Mystery")
        let stmt = try db.prepare("SELECT category FROM ingredients WHERE slug = 'mystery';")
        defer { stmt.finalize() }
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.text(0), "other")
    }

    func testAliasPrimaryKeyRefusesASecondOwner() throws {
        try insertIngredient("vegetable_broth", "Vegetable broth")
        try insertIngredient("chicken_broth", "Chicken broth")
        try db.execute("INSERT INTO ingredient_aliases (alias, ingredient_id, is_custom) VALUES ('veggie broth', 1, 0);")
        // An alias cannot be owned by two canonicals (PRIMARY KEY) — it falls
        // through to "ask" instead of resolving wrong.
        XCTAssertThrowsError(try db.execute(
            "INSERT INTO ingredient_aliases (alias, ingredient_id, is_custom) VALUES ('veggie broth', 2, 1);"
        ))
        // The seed's INSERT OR IGNORE keeps the existing owner rather than failing.
        try db.execute("INSERT OR IGNORE INTO ingredient_aliases (alias, ingredient_id, is_custom) VALUES ('veggie broth', 2, 0);")
        let stmt = try db.prepare("SELECT ingredient_id FROM ingredient_aliases WHERE alias = 'veggie broth';")
        defer { stmt.finalize() }
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.int(0), 1)
        XCTAssertEqual(try count("ingredient_aliases"), 1)
        // Deleting the owner cascades to its aliases.
        try db.execute("DELETE FROM ingredients WHERE id = 1;")
        XCTAssertEqual(try count("ingredient_aliases"), 0, "aliases cascade with their owning ingredient")
    }

    // MARK: - Transactions

    func testTransactionCommitsOnSuccess() throws {
        try db.transaction {
            try insertRecipe("Soup")
        }
        XCTAssertEqual(try count("recipes"), 1)
    }

    func testTransactionRollsBackOnError() throws {
        struct Boom: Error {}
        XCTAssertThrowsError(try db.transaction {
            try insertRecipe("Soup")
            throw Boom()
        })
        XCTAssertEqual(try count("recipes"), 0, "a failed transaction leaves nothing behind")
    }

    // MARK: - Foreign keys

    func testForeignKeyCascadeDeletesRecipeIngredients() throws {
        // Passes only when PRAGMA foreign_keys = ON and ON DELETE CASCADE fire.
        try insertIngredient("garlic", "Garlic")
        try insertRecipe("Soup")
        try insertRow(recipe: 1, ingredient: 1, line: "2 cloves garlic")
        try insertRow(recipe: 1, ingredient: nil, line: "a splash of something")
        XCTAssertEqual(try count("recipe_ingredients"), 2)

        try db.execute("DELETE FROM recipes WHERE id = 1;")
        XCTAssertEqual(try count("recipe_ingredients"), 0, "deleting a recipe cascades to its rows")
        XCTAssertEqual(try count("ingredients"), 1, "ingredients are not cascade-deleted")
    }

    /// `recipe_ingredients.ingredient_id` is ON DELETE SET NULL: the row survives as
    /// kept-as-text instead of vanishing ("nothing silently dropped"), while the
    /// ingredient's aliases and its check row cascade away with it.
    func testDeletingAnIngredientSetsRowsNullAndCascadesAliasesAndChecks() throws {
        try insertIngredient("garlic", "Garlic")
        try insertRecipe("Soup")
        try insertRow(recipe: 1, ingredient: 1, line: "2 cloves garlic")
        try db.execute("INSERT INTO ingredient_aliases (alias, ingredient_id, is_custom) VALUES ('garlic clove', 1, 0);")
        try db.execute("INSERT INTO check_state (ingredient_id, checked_at) VALUES (1, 't');")

        try db.execute("DELETE FROM ingredients WHERE id = 1;")

        XCTAssertEqual(try count("recipe_ingredients"), 1, "the recipe row is kept")
        let stmt = try db.prepare("SELECT ingredient_id FROM recipe_ingredients WHERE recipe_id = 1;")
        defer { stmt.finalize() }
        XCTAssertTrue(try stmt.step())
        XCTAssertNil(stmt.optionalInt64(0), "the row now reads as kept-as-text")
        XCTAssertEqual(try count("ingredient_aliases"), 0)
        XCTAssertEqual(try count("check_state"), 0, "check_state cascades with its ingredient")
    }

    func testCheckStateRequiresARealIngredient() throws {
        XCTAssertThrowsError(try db.execute("INSERT INTO check_state (ingredient_id, checked_at) VALUES (42, 't');"))
        try insertIngredient("garlic", "Garlic")
        try db.execute("INSERT INTO check_state (ingredient_id, checked_at) VALUES (1, 't');")
        // Presence-based: a second check is an upsert, never a second row.
        try db.execute("INSERT OR REPLACE INTO check_state (ingredient_id, checked_at) VALUES (1, 't2');")
        XCTAssertEqual(try count("check_state"), 1)
    }

    // MARK: - readTransaction

    /// `readTransaction` opens BEGIN DEFERRED, runs the body, commits, and returns
    /// the body's value; the connection stays writable afterwards.
    func testReadTransactionRunsBodyAndCommits() throws {
        try insertIngredient("garlic", "Garlic")
        let observed = try db.readTransaction { try count("ingredients") }
        XCTAssertEqual(observed, 1)
        try insertIngredient("onion", "Onion")
        XCTAssertEqual(try count("ingredients"), 2)
    }

    func testReadTransactionRollsBackOnThrow() throws {
        struct Boom: Error {}
        try insertIngredient("garlic", "Garlic")
        XCTAssertThrowsError(try db.readTransaction { () throws -> Void in throw Boom() })
        // After a ROLLBACK the connection is in a clean state — the next write works.
        try insertIngredient("onion", "Onion")
        XCTAssertEqual(try count("ingredients"), 2)
    }

    /// The list snapshot (`groceryListInput`) reads three tables and must see one
    /// consistent state. Verified with a **separate** connection to the same file
    /// (WAL allows readers + one writer): a write committed mid-read is invisible
    /// to the reader's later SELECT and visible after the snapshot ends.
    func testReadTransactionGivesConsistentSnapshotUnderConcurrentWrite() throws {
        try insertIngredient("seeded", "Seeded")
        let reader = try SQLiteDB(path: path)

        func ingredientCount(on connection: SQLiteDB) throws -> Int {
            let stmt = try connection.prepare("SELECT COUNT(*) FROM ingredients;")
            defer { stmt.finalize() }
            return try stmt.step() ? Int(stmt.int(0)) : 0
        }

        var observedInsideTxn: [Int] = []
        try reader.readTransaction {
            observedInsideTxn.append(try ingredientCount(on: reader))
            try self.insertIngredient("mid_read", "Mid Read")   // writer commits mid-snapshot
            observedInsideTxn.append(try ingredientCount(on: reader))
        }

        XCTAssertEqual(observedInsideTxn, [1, 1],
                       "both queries inside the read transaction see the pre-write snapshot")
        XCTAssertEqual(try ingredientCount(on: reader), 2, "after the snapshot ends the commit is visible")
    }

    /// Nesting-aware: called while a transaction is already open on this connection
    /// (a wrapped store read inside `save`, e.g. `uniqueSlug` → `ingredientID(slug:)`),
    /// the body runs inside the enclosing transaction instead of issuing a second
    /// BEGIN, which SQLite rejects.
    func testReadTransactionNestsInsideWriteTransaction() throws {
        try db.transaction {
            try insertIngredient("garlic", "Garlic")
            let observed = try db.readTransaction { try count("ingredients") }
            XCTAssertEqual(observed, 1, "the nested read sees our own uncommitted row")
        }
        XCTAssertEqual(try count("ingredients"), 1)
    }

    /// Opening a write transaction inside a snapshot is a caller bug and fails with
    /// the store-specific diagnostic, leaving the connection clean.
    func testWriteTransactionInsideReadTransactionThrowsClearDiagnostic() throws {
        XCTAssertThrowsError(try db.readTransaction {
            try db.transaction {
                try insertIngredient("bad", "Bad")
            }
        }) { error in
            XCTAssertTrue("\(error)".contains("not allowed inside readTransaction/snapshot"),
                          "expected the writes-inside-read diagnostic, got: \(error)")
        }
        try db.transaction { try insertIngredient("good", "Good") }
        XCTAssertEqual(try count("ingredients"), 1)
    }

    /// Statement-level enforcement: a raw INSERT prepared directly inside a snapshot
    /// (bypassing `transaction`) is refused by `sqlite3_stmt_readonly` before it can
    /// silently upgrade the deferred transaction to a write.
    func testRawWriteStatementInsideReadTransactionIsRefused() throws {
        XCTAssertThrowsError(try db.readTransaction { () throws -> Void in
            let stmt = try db.prepare("INSERT INTO manual_items (text, created_at) VALUES ('sneaky', 't');")
            stmt.finalize()
        }) { error in
            XCTAssertTrue("\(error)".contains("snapshots are reads-only"),
                          "expected the reads-only diagnostic, got: \(error)")
        }
        XCTAssertEqual(try count("manual_items"), 0)
        // A SELECT prepared inside a snapshot is fine.
        let observed = try db.readTransaction { try count("manual_items") }
        XCTAssertEqual(observed, 0)
    }

    /// The connection lock's core guarantee: a transaction body is atomic against
    /// concurrent readers on the SAME connection, not just each C call. Writers
    /// insert two ingredients per transaction while readers hammer the count; an
    /// odd count would mean a read interleaved into an open transaction.
    func testTransactionBodyIsAtomicAgainstConcurrentSameConnectionReads() throws {
        let db = try XCTUnwrap(self.db)
        let iterations = 50
        let group = DispatchGroup()
        var oddObservations = 0
        let oddLock = NSLock()

        DispatchQueue(label: "writer").async(group: group) {
            for i in 0..<iterations {
                try? db.transaction {
                    try db.execute("INSERT INTO ingredients (slug, canonical_name, created_at) VALUES ('a\(i)', 'A\(i)', 't');")
                    try db.execute("INSERT INTO ingredients (slug, canonical_name, created_at) VALUES ('b\(i)', 'B\(i)', 't');")
                }
            }
        }
        DispatchQueue(label: "reader").async(group: group) {
            for _ in 0..<(iterations * 4) {
                let observed = (try? db.readTransaction { () throws -> Int in
                    let stmt = try db.prepare("SELECT COUNT(*) FROM ingredients;")
                    defer { stmt.finalize() }
                    return try stmt.step() ? Int(stmt.int(0)) : 0
                }) ?? 0
                if observed % 2 != 0 {
                    oddLock.lock(); oddObservations += 1; oddLock.unlock()
                }
            }
        }
        group.wait()

        XCTAssertEqual(oddObservations, 0,
                       "a reader observed an odd ingredient count — it interleaved into an open write transaction")
        XCTAssertEqual(try count("ingredients"), iterations * 2,
                       "every writer transaction must have committed cleanly")
    }
}
