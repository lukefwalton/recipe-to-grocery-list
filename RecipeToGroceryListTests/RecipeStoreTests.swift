import XCTest
@testable import RecipeToGroceryList

/// Store semantics at the store's own altitude (spec §11 "Store tests"): the one
/// write path, seed upsert idempotency, alias PK refusal, check-state GC on
/// deselect and delete, and the list snapshot as the pure function's input.
/// Connection/schema guarantees (rollback, cascades, CHECKs) live in
/// `SQLiteDBTests`; the list's ordering and sums in `GroceryListTests`.
///
/// Ported in shape from `workout-logger` `WorkoutChatLogTests/WorkoutStoreTests.swift`
/// (@5bffddfb80fc). A tiny hand-written seed keeps these deterministic; the real
/// bundled seed's invariants are `SeedIngredientsTests`' job.
@MainActor
final class RecipeStoreTests: XCTestCase {

    private var dbPath: String!
    private var store: RecipeStore!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "rtg-store-\(UUID().uuidString).sqlite"
        store = RecipeStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
    }

    override func tearDownWithError() throws {
        store = nil   // close the connection before deleting files
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    // MARK: - Fixtures

    private static let fixture: [SeedIngredient] = [
        SeedIngredient(slug: "garlic", canonicalName: "Garlic", category: .produce,
                       aliases: ["garlic cloves", "fresh garlic"]),
        SeedIngredient(slug: "onion", canonicalName: "Onion", category: .produce,
                       aliases: ["yellow onion"]),
        SeedIngredient(slug: "butter", canonicalName: "Butter", category: .dairy,
                       aliases: ["unsalted butter"]),
        SeedIngredient(slug: "vegetable_broth", canonicalName: "Vegetable broth", category: .pantry,
                       aliases: ["veggie broth", "vegetable stock", "veggie stock"]),
        SeedIngredient(slug: "chicken_broth", canonicalName: "Chicken broth", category: .pantry,
                       aliases: ["chicken stock"]),
    ]

    private var fixtureAliasCount: Int { Self.fixture.reduce(0) { $0 + $1.aliases.count } }

    private func seedFixture() throws {
        try store.seedIngredientsIfNeeded(Self.fixture)
    }

    private func id(_ slug: String) throws -> Int64 {
        try XCTUnwrap(store.ingredientID(slug: slug), "fixture slug \(slug)")
    }

    private func makeRow(_ rawLine: String,
                         name: String,
                         ingredient: IngredientRef?,
                         resolution: RowResolution = .exact,
                         quantity: Double? = nil,
                         unitKey: String? = nil,
                         unitText: String? = nil,
                         note: String? = nil,
                         keepAsText: Bool = false,
                         isRemoved: Bool = false,
                         lineIndex: Int = 0) -> DraftRow {
        DraftRow(lineIndex: lineIndex,
                 rawLine: rawLine,
                 name: name,
                 quantity: quantity,
                 unitKey: unitKey,
                 unitText: unitText,
                 note: note,
                 ingredient: ingredient,
                 resolution: keepAsText ? .none : resolution,
                 confidence: .high,
                 keepAsText: keepAsText,
                 isRemoved: isRemoved)
    }

    private func makeDraft(title: String = "Lentil soup",
                           rows: [DraftRow],
                           rawLines: [String]? = nil,
                           source: RecipeSource = RecipeSource(kind: .text),
                           newIngredients: [PendingIngredient] = [],
                           newAliases: [PendingAlias] = []) -> RecipeDraft {
        RecipeDraft(title: title,
                    source: source,
                    rawLines: rawLines ?? rows.map(\.rawLine),
                    rows: rows,
                    newIngredients: newIngredients,
                    newAliases: newAliases)
    }

    /// Two recipes sharing garlic — the §9 GC scenario. Soup is saved first.
    private func saveSoupAndRisotto() throws -> (soup: Int64, risotto: Int64) {
        let garlic = try id("garlic")
        let onion = try id("onion")
        let butter = try id("butter")
        let soup = try store.save(makeDraft(title: "Lentil soup", rows: [
            makeRow("3 cloves garlic", name: "garlic", ingredient: .existing(garlic),
                    quantity: 3, unitKey: "clove", lineIndex: 0),
            makeRow("1 onion", name: "onion", ingredient: .existing(onion), quantity: 1, lineIndex: 1),
        ]))
        let risotto = try store.save(makeDraft(title: "Risotto", rows: [
            makeRow("2 cloves garlic", name: "garlic", ingredient: .existing(garlic), resolution: .alias,
                    quantity: 2, unitKey: "clove", lineIndex: 0),
            makeRow("2 tbsp butter", name: "butter", ingredient: .existing(butter),
                    quantity: 2, unitKey: "tbsp", lineIndex: 1),
        ]))
        return (soup, risotto)
    }

    // MARK: - Migration & seeding

    func testMigrationStampsSchemaVersion() throws {
        XCTAssertEqual(try store.schemaVersion(), Schema.latestVersion)
    }

    func testSeedingIsIdempotent() throws {
        try seedFixture()
        XCTAssertEqual(try store.ingredientCount(), Self.fixture.count)
        XCTAssertEqual(try store.count(inTable: "ingredient_aliases"), fixtureAliasCount)
        try seedFixture()   // reseed upserts on slug — no duplicate rows, no duplicate aliases
        try seedFixture()
        XCTAssertEqual(try store.ingredientCount(), Self.fixture.count)
        XCTAssertEqual(try store.count(inTable: "ingredient_aliases"), fixtureAliasCount)
    }

    func testBundledSeedLoadsOnceAndEveryAliasResolvesToItsOwner() throws {
        let seeds = try IngredientSeed.load(from: Bundle(for: Self.self))
        try store.seedIngredientsIfNeeded(seeds)
        try store.seedIngredientsIfNeeded(seeds)
        XCTAssertEqual(try store.ingredientCount(), seeds.count)
        for seed in seeds {
            let owner = try id(seed.slug)
            let stored = try XCTUnwrap(store.ingredient(id: owner))
            XCTAssertFalse(stored.isCustom, "\(seed.slug) is seeded, not custom")
            XCTAssertEqual(stored.category, seed.category)
            XCTAssertEqual(stored.canonicalName, seed.canonicalName)
            for alias in seed.aliases {
                XCTAssertEqual(try store.aliasOwner(alias), owner,
                               "seed alias \"\(alias)\" must resolve to \(seed.canonicalName)")
            }
        }
    }

    func testRenamedCanonicalSurvivesReseedWhileCategoryRefreshes() throws {
        try seedFixture()
        let garlic = try id("garlic")
        // v1 has no rename UI (§6); simulate the v1.1 rename at the connection.
        try store.db.execute("UPDATE ingredients SET canonical_name = 'Garlic (fresh)' WHERE slug = 'garlic';")

        var changed = Self.fixture
        changed[0].category = .pantry
        changed[0].aliases.append("garlic bulb")
        try store.seedIngredientsIfNeeded(changed)

        let stored = try XCTUnwrap(store.ingredient(id: garlic))
        XCTAssertEqual(stored.canonicalName, "Garlic (fresh)", "the seed never overwrites a renamed canonical")
        XCTAssertEqual(stored.category, .pantry, "seed-owned category is refreshed")
        XCTAssertFalse(stored.isCustom, "is_custom is never touched by a reseed")
        XCTAssertEqual(stored.slug, "garlic")
        XCTAssertEqual(try store.aliasOwner("garlic bulb"), garlic, "new seed aliases are added on reseed")
        XCTAssertEqual(try store.ingredientCount(), Self.fixture.count)
    }

    func testReseedNeverStealsAUserAlias() throws {
        try seedFixture()
        let chicken = try id("chicken_broth")
        // The user said "stock" means chicken broth in their kitchen…
        try store.save(makeDraft(rows: [
            makeRow("2 cups stock", name: "stock", ingredient: .existing(chicken), resolution: .user,
                    quantity: 2, unitKey: "cup"),
        ], newAliases: [PendingAlias(alias: "stock", target: .existing(chicken))]))
        // …and a later seed wants "stock" for vegetable broth.
        var changed = Self.fixture
        changed[3].aliases.append("stock")
        try store.seedIngredientsIfNeeded(changed)
        XCTAssertEqual(try store.aliasOwner("stock"), chicken, "INSERT OR IGNORE keeps the user's owner")
    }

    // MARK: - Registry reads

    func testAliasLookupUsesTheOneNormalization() throws {
        try seedFixture()
        let broth = try id("vegetable_broth")
        XCTAssertEqual(try store.aliasOwner("veggie broth"), broth)
        XCTAssertEqual(try store.aliasOwner("  Veggie   Stocks "), broth, "case, whitespace and a plural fold")
        XCTAssertEqual(try store.aliasOwner("the vegetable stock (low sodium)"), broth, "article and parenthetical fold")
        XCTAssertNil(try store.aliasOwner("moon dust"))
        XCTAssertNil(try store.aliasOwner("   "))
        XCTAssertEqual(RecipeStore.normalizeAlias("Veggie Stocks"), IngredientNormalizer.normalize("Veggie Stocks"))
        XCTAssertEqual(RecipeStore.slugify("Crème Fraîche"), IngredientNormalizer.slugify("Crème Fraîche"))
    }

    func testIngredientReadsAndCaseInsensitiveOrdering() throws {
        try seedFixture()
        XCTAssertEqual(try store.allIngredients().map(\.canonicalName),
                       ["Butter", "Chicken broth", "Garlic", "Onion", "Vegetable broth"])
        let butterID = try id("butter")
        let butter = try XCTUnwrap(store.ingredient(id: butterID))
        XCTAssertEqual(butter, Ingredient(id: butterID, slug: "butter", canonicalName: "Butter", category: .dairy, isCustom: false))
        XCTAssertNil(try store.ingredient(id: 999_999))
        XCTAssertNil(try store.ingredientID(slug: "unicorn"))
        XCTAssertTrue(try store.ingredientExists(butter.id))
        XCTAssertFalse(try store.ingredientExists(999_999))
    }

    func testIngredientIndexCarriesEveryCanonicalWithItsAliases() throws {
        try seedFixture()
        let index = try store.ingredientIndex()
        XCTAssertEqual(index.entries.count, Self.fixture.count)
        XCTAssertEqual(index.entries.map(\.id), index.entries.map(\.id).sorted(), "ordered by id for a stable embedding cache")
        let broth = try id("vegetable_broth")
        let entry = try XCTUnwrap(index.entries.first { $0.id == broth })
        XCTAssertEqual(entry.canonicalName, "Vegetable broth")
        XCTAssertEqual(entry.category, .pantry)
        XCTAssertEqual(Set(entry.aliases), ["veggie broth", "vegetable stock", "veggie stock"], "aliases as stored (normalized)")
        XCTAssertEqual(try store.aliasesByIngredient()[broth]?.count, 3)
    }

    // MARK: - The write path

    func testSaveRoundTripsEveryRawLineAndRowsInOrder() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let onion = try id("onion")
        let rawLines = ["For the soup:", "2 cloves garlic, minced", "1 large onion", "a splash of something", "Salt"]
        let draft = makeDraft(title: "  Lentil soup ", rows: [
            makeRow("2 cloves garlic, minced", name: "garlic", ingredient: .existing(garlic),
                    quantity: 2, unitKey: "clove", unitText: "cloves", note: "minced", lineIndex: 1),
            makeRow("1 large onion", name: "onion", ingredient: .existing(onion), resolution: .fuzzy,
                    quantity: 1, note: "large", lineIndex: 2),
            makeRow("a splash of something", name: "a splash of something", ingredient: nil, keepAsText: true, lineIndex: 3),
            makeRow("Salt", name: "salt", ingredient: nil, resolution: .none, isRemoved: true, lineIndex: 4),
        ], rawLines: rawLines,
           source: RecipeSource(kind: .url, ref: "https://example.com/soup", titleGuess: nil, servingsText: "Serves 4"))

        let recipeID = try store.save(draft)

        let recipe = try XCTUnwrap(store.recipe(id: recipeID))
        XCTAssertEqual(recipe.title, "Lentil soup", "title is trimmed")
        XCTAssertEqual(recipe.rawLines, rawLines, "every raw line survives — header and removed line included")
        XCTAssertEqual(recipe.sourceKind, .url)
        XCTAssertEqual(recipe.sourceRef, "https://example.com/soup")
        XCTAssertEqual(recipe.servingsText, "Serves 4")
        XCTAssertFalse(recipe.isSelected, "saving never selects")
        XCTAssertEqual(recipe.lineCount, 3, "a removed row is not an ingredient row")
        XCTAssertEqual(try store.recipes(), [recipe])

        let rows = try store.recipeIngredients(recipeID: recipeID)
        XCTAssertEqual(rows.map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(rows.map(\.rawLine), ["2 cloves garlic, minced", "1 large onion", "a splash of something"])
        XCTAssertEqual(rows.map(\.recipeID), [recipeID, recipeID, recipeID])
        XCTAssertEqual(rows[0].ingredientID, garlic)
        XCTAssertEqual(rows[0].name, "garlic")
        XCTAssertEqual(rows[0].quantity, 2)
        XCTAssertEqual(rows[0].unitKey, "clove")
        XCTAssertEqual(rows[0].unitText, "cloves")
        XCTAssertEqual(rows[0].note, "minced")
        XCTAssertEqual(rows[0].resolution, .exact)
        XCTAssertEqual(rows[1].ingredientID, onion)
        XCTAssertEqual(rows[1].resolution, .fuzzy, "provenance is stored verbatim")
        XCTAssertNil(rows[1].unitKey)
        XCTAssertNil(rows[1].unitText)
        XCTAssertEqual(rows[1].note, "large")
    }

    func testKeepAsTextRowHasNullIngredient() throws {
        try seedFixture()
        let recipeID = try store.save(makeDraft(rows: [
            makeRow("a splash of something", name: "a splash of something", ingredient: nil, keepAsText: true),
        ]))
        let row = try XCTUnwrap(store.recipeIngredients(recipeID: recipeID).first)
        XCTAssertNil(row.ingredientID, "kept as text ⇒ NULL ingredient_id")
        XCTAssertEqual(row.resolution, RowResolution.none)
        XCTAssertEqual(row.name, "a splash of something")
        XCTAssertEqual(row.rawLine, "a splash of something")
    }

    func testSavingAPendingIngredientCreatesItAsCustomWithAGeneratedSlug() throws {
        try seedFixture()
        let pending = PendingIngredient(name: "  Za'atar ", category: .pantry)
        let recipeID = try store.save(makeDraft(rows: [
            makeRow("1 tbsp za'atar", name: "za'atar", ingredient: .pending(pending.id), resolution: .user,
                    quantity: 1, unitKey: "tbsp"),
        ], newIngredients: [pending]))

        let zaatarID = try id("zaatar")
        let zaatar = try XCTUnwrap(store.ingredient(id: zaatarID))
        XCTAssertEqual(zaatar.canonicalName, "Za'atar", "trimmed, casing preserved")
        XCTAssertEqual(zaatar.category, .pantry)
        XCTAssertTrue(zaatar.isCustom)
        XCTAssertEqual(zaatar.slug, "zaatar")
        XCTAssertEqual(try store.recipeIngredients(recipeID: recipeID).first?.ingredientID, zaatarID,
                       "the row points at the id minted inside the same transaction")
        XCTAssertEqual(try store.ingredientCount(), Self.fixture.count + 1)
    }

    func testCustomSlugNeverCollidesWithAnExistingSlug() throws {
        try seedFixture()
        let pending = PendingIngredient(name: "Garlic", category: .produce)   // a duplicate the user insisted on
        try store.save(makeDraft(rows: [
            makeRow("garlic", name: "garlic", ingredient: .pending(pending.id), resolution: .user),
        ], newIngredients: [pending]))
        let second = try id("garlic_2")
        XCTAssertNotEqual(second, try id("garlic"))
        XCTAssertEqual(try store.ingredient(id: second)?.canonicalName, "Garlic")
        XCTAssertEqual(try store.uniqueSlug(forName: "Garlic"), "garlic_3")
        XCTAssertEqual(try store.uniqueSlug(forName: "Onion"), "onion_2")
        XCTAssertEqual(try store.uniqueSlug(forName: "Harissa"), "harissa")
        XCTAssertEqual(try store.uniqueSlug(forName: "***"), "ingredient", "a name with no letters still gets a stem")
    }

    func testSaveWritesAliasesFromSameAsAndUse() throws {
        try seedFixture()
        let broth = try id("vegetable_broth")
        let pending = PendingIngredient(name: "Harissa", category: .pantry)
        try store.save(makeDraft(rows: [
            makeRow("2 cups veg stock", name: "veg stock", ingredient: .existing(broth), resolution: .user,
                    quantity: 2, unitKey: "cup"),
            makeRow("1 tbsp harissa paste", name: "harissa paste", ingredient: .pending(pending.id), resolution: .user,
                    quantity: 1, unitKey: "tbsp", lineIndex: 1),
        ], newIngredients: [pending], newAliases: [
            PendingAlias(alias: "Veg Stock", target: .existing(broth)),
            PendingAlias(alias: "harissa paste", target: .pending(pending.id)),
            PendingAlias(alias: "veggie broth", target: .existing(broth)),   // already the owner → no-op
        ]))

        XCTAssertEqual(try store.aliasOwner("veg stock"), broth, "stored normalized")
        XCTAssertEqual(try store.aliasOwner("harissa paste"), try id("harissa"), "an alias can target a pending ingredient")
        XCTAssertEqual(try store.count(inTable: "ingredient_aliases"), fixtureAliasCount + 2)

        // User-written aliases are marked is_custom so a future merge can tell them apart.
        let stmt = try store.db.prepare("SELECT is_custom FROM ingredient_aliases WHERE alias = 'veg stock';")
        defer { stmt.finalize() }
        XCTAssertTrue(try stmt.step())
        XCTAssertEqual(stmt.int(0), 1)
    }

    func testAliasOwnedElsewhereRollsBackTheWholeSave() throws {
        try seedFixture()
        let chicken = try id("chicken_broth")
        let broth = try id("vegetable_broth")
        let pending = PendingIngredient(name: "Harissa", category: .pantry)
        let draft = makeDraft(rows: [
            makeRow("2 cups veggie broth", name: "veggie broth", ingredient: .existing(chicken), resolution: .user,
                    quantity: 2, unitKey: "cup"),
            makeRow("1 tbsp harissa", name: "harissa", ingredient: .pending(pending.id), resolution: .user, lineIndex: 1),
        ], newIngredients: [pending], newAliases: [
            PendingAlias(alias: "Veggie Broth", target: .existing(chicken)),   // "veggie broth" already means Vegetable broth
        ])

        XCTAssertThrowsError(try store.save(draft)) { error in
            XCTAssertEqual(error as? RecipeStoreError,
                           .aliasOwnedElsewhere(alias: "veggie broth", ownerName: "Vegetable broth"))
            XCTAssertEqual("\(error)", "\"veggie broth\" already means Vegetable broth")
        }
        XCTAssertEqual(try store.count(inTable: "recipes"), 0, "no recipe row")
        XCTAssertEqual(try store.count(inTable: "recipe_ingredients"), 0)
        XCTAssertEqual(try store.ingredientCount(), Self.fixture.count, "the pending ingredient rolled back too")
        XCTAssertEqual(try store.count(inTable: "ingredient_aliases"), fixtureAliasCount)
        XCTAssertEqual(try store.aliasOwner("veggie broth"), broth, "the existing owner is untouched")
        XCTAssertNil(try store.ingredientID(slug: "harissa"))
    }

    func testSaveRejectsAnUnknownExistingIngredientAndWritesNothing() throws {
        try seedFixture()
        XCTAssertThrowsError(try store.save(makeDraft(rows: [
            makeRow("1 unicorn horn", name: "unicorn horn", ingredient: .existing(999_999)),
        ]))) { error in
            XCTAssertEqual(error as? RecipeStoreError, .unknownIngredient(999_999))
        }
        XCTAssertEqual(try store.count(inTable: "recipes"), 0)
    }

    func testInvalidDraftThrowsAndWritesNothing() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let pending = PendingIngredient(name: "Harissa", category: .pantry)
        let blankTitle = makeDraft(title: "   ", rows: [
            makeRow("1 clove garlic", name: "garlic", ingredient: .existing(garlic)),
        ], newIngredients: [pending])
        XCTAssertThrowsError(try store.save(blankTitle)) { error in
            XCTAssertEqual(error as? RecipeValidationError, .emptyTitle)
        }
        XCTAssertEqual(try store.count(inTable: "recipes"), 0)
        XCTAssertEqual(try store.ingredientCount(), Self.fixture.count, "validation runs before the transaction opens")

        // A row still waiting on a tap is refused too (§7.5).
        XCTAssertThrowsError(try store.save(makeDraft(rows: [
            makeRow("mystery powder", name: "mystery powder", ingredient: nil, resolution: .none),
        ]))) { error in
            XCTAssertEqual(error as? RecipeValidationError, .rowStillNeedsDecision(line: "mystery powder"))
        }
        XCTAssertEqual(try store.count(inTable: "recipes"), 0)
        XCTAssertEqual(try store.count(inTable: "recipe_ingredients"), 0)
    }

    // MARK: - Recipes screen

    func testRecipesNewestFirstWithLineCounts() throws {
        try seedFixture()
        let (soup, risotto) = try saveSoupAndRisotto()
        let list = try store.recipes()
        XCTAssertEqual(list.map(\.id), [risotto, soup], "newest first (created_at DESC, id DESC)")
        XCTAssertEqual(list.map(\.title), ["Risotto", "Lentil soup"])
        XCTAssertEqual(list.map(\.lineCount), [2, 2])
        XCTAssertEqual(list.map(\.isSelected), [false, false])
        XCTAssertEqual(list.map(\.sourceKind), [.text, .text])
        XCTAssertNil(try store.recipe(id: 999))
    }

    func testSelectionToggleAndCount() throws {
        try seedFixture()
        let (soup, risotto) = try saveSoupAndRisotto()
        XCTAssertEqual(try store.selectedRecipeCount(), 0)
        try store.setSelected(soup, true)
        XCTAssertEqual(try store.selectedRecipeCount(), 1)
        XCTAssertEqual(try store.recipe(id: soup)?.isSelected, true)
        XCTAssertEqual(try store.recipe(id: risotto)?.isSelected, false)
        try store.setSelected(soup, false)
        XCTAssertEqual(try store.selectedRecipeCount(), 0)
        XCTAssertThrowsError(try store.setSelected(999, true)) { error in
            XCTAssertEqual(error as? RecipeStoreError, .unknownRecipe(999))
        }
    }

    func testRenameRecipeTrimsAndRejectsBlankOrUnknown() throws {
        try seedFixture()
        let (soup, _) = try saveSoupAndRisotto()
        try store.renameRecipe(soup, title: "  Red lentil soup ")
        XCTAssertEqual(try store.recipe(id: soup)?.title, "Red lentil soup")
        XCTAssertThrowsError(try store.renameRecipe(soup, title: "   ")) { error in
            XCTAssertEqual(error as? RecipeStoreError, .emptyName)
        }
        XCTAssertThrowsError(try store.renameRecipe(999, title: "Ghost")) { error in
            XCTAssertEqual(error as? RecipeStoreError, .unknownRecipe(999))
        }
        XCTAssertEqual(try store.recipe(id: soup)?.title, "Red lentil soup", "a refused rename changes nothing")
        XCTAssertEqual(try store.recipeIngredients(recipeID: soup).count, 2, "rows are untouched by a rename")
    }

    // MARK: - Check-state GC (§9)

    func testDeselectingKeepsACheckWhileAnotherSelectedRecipeContributes() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let onion = try id("onion")
        let (soup, risotto) = try saveSoupAndRisotto()
        try store.setSelected(soup, true)
        try store.setSelected(risotto, true)
        try store.setChecked(ingredientID: garlic, true)
        try store.setChecked(ingredientID: onion, true)
        XCTAssertEqual(try store.groceryListInput().checkedIngredientIDs, [garlic, onion])

        try store.setSelected(soup, false)
        XCTAssertEqual(try store.groceryListInput().checkedIngredientIDs, [garlic],
                       "garlic is still in risotto; onion left the list and its check went with it")

        try store.setSelected(risotto, false)
        XCTAssertEqual(try store.groceryListInput().checkedIngredientIDs, [],
                       "no selected recipe contributes garlic any more")
        XCTAssertEqual(try store.count(inTable: "check_state"), 0)
    }

    func testReselectingAfterGCShowsNoStaleCheck() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let (soup, _) = try saveSoupAndRisotto()
        try store.setSelected(soup, true)
        try store.setChecked(ingredientID: garlic, true)
        try store.setSelected(soup, false)
        try store.setSelected(soup, true)
        XCTAssertFalse(try store.groceryListInput().checkedIngredientIDs.contains(garlic),
                       "next week's list starts unchecked")
    }

    func testUncheckingRemovesTheRowAndReCheckingIsIdempotent() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let (soup, _) = try saveSoupAndRisotto()
        try store.setSelected(soup, true)
        try store.setChecked(ingredientID: garlic, true)
        try store.setChecked(ingredientID: garlic, true)
        XCTAssertEqual(try store.count(inTable: "check_state"), 1, "presence-based: one row per ingredient")
        try store.setChecked(ingredientID: garlic, false)
        XCTAssertEqual(try store.count(inTable: "check_state"), 0)
        XCTAssertNoThrow(try store.setChecked(ingredientID: garlic, false), "unchecking twice is harmless")
    }

    func testSetCheckedRejectsAnUnknownIngredient() throws {
        try seedFixture()
        XCTAssertThrowsError(try store.setChecked(ingredientID: 999_999, true)) { error in
            XCTAssertEqual(error as? RecipeStoreError, .unknownIngredient(999_999))
        }
        XCTAssertEqual(try store.count(inTable: "check_state"), 0)
    }

    func testDeleteRecipeCascadesRowsAndRunsTheSameGC() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let butter = try id("butter")
        let (soup, risotto) = try saveSoupAndRisotto()
        try store.setSelected(soup, true)
        try store.setSelected(risotto, true)
        try store.setChecked(ingredientID: garlic, true)
        try store.setChecked(ingredientID: butter, true)

        try store.deleteRecipe(risotto)
        XCTAssertNil(try store.recipe(id: risotto))
        XCTAssertEqual(try store.recipeIngredients(recipeID: risotto), [], "rows cascade with the recipe")
        XCTAssertEqual(try store.count(inTable: "recipe_ingredients"), 2)
        XCTAssertEqual(try store.groceryListInput().checkedIngredientIDs, [garlic],
                       "butter left with risotto; garlic stays via soup")

        try store.deleteRecipe(soup)
        XCTAssertEqual(try store.count(inTable: "check_state"), 0)
        XCTAssertEqual(try store.recipes(), [])
        XCTAssertEqual(try store.ingredientCount(), Self.fixture.count, "ingredients are never deleted with a recipe")
        XCTAssertNoThrow(try store.deleteRecipe(soup), "deleting an already-deleted recipe is a no-op")
    }

    func testDeselectAllRecipesRunsTheGC() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let (soup, risotto) = try saveSoupAndRisotto()
        try store.setSelected(soup, true)
        try store.setSelected(risotto, true)
        try store.setChecked(ingredientID: garlic, true)
        try store.deselectAllRecipes()
        XCTAssertEqual(try store.selectedRecipeCount(), 0)
        XCTAssertEqual(try store.count(inTable: "check_state"), 0)
        XCTAssertEqual(try store.recipes().count, 2, "deselecting deletes nothing")
    }

    // MARK: - The list snapshot (§9)

    func testGroceryListInputOnlyIncludesSelectedRecipesInOrder() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let (soup, risotto) = try saveSoupAndRisotto()
        XCTAssertEqual(try store.groceryListInput(), .empty, "nothing selected, nothing typed, nothing checked")

        try store.setSelected(risotto, true)
        var input = try store.groceryListInput()
        XCTAssertEqual(input.rows.map(\.recipeID), [risotto, risotto])
        XCTAssertEqual(input.rows.map(\.recipeTitle), ["Risotto", "Risotto"])
        XCTAssertEqual(input.rows.map(\.sortOrder), [0, 1])

        try store.setSelected(soup, true)
        input = try store.groceryListInput()
        XCTAssertEqual(input.rows.map(\.recipeID), [soup, soup, risotto, risotto],
                       "recipes in created order, rows in sort order")
        let garlicRow = input.rows[0]
        XCTAssertEqual(garlicRow.ingredientID, garlic)
        XCTAssertEqual(garlicRow.ingredientName, "Garlic")
        XCTAssertEqual(garlicRow.category, .produce)
        XCTAssertEqual(garlicRow.name, "garlic")
        XCTAssertEqual(garlicRow.quantity, 3)
        XCTAssertEqual(garlicRow.unitKey, "clove")
        XCTAssertEqual(garlicRow.recipeTitle, "Lentil soup")

        // The snapshot is exactly what the pure builder consumes.
        let list = GroceryListBuilder.build(input)
        XCTAssertEqual(list.sections.map(\.category), [.produce, .dairy])
        XCTAssertEqual(list.sections[0].groups.map(\.name), ["Garlic", "Onion"])
        XCTAssertEqual(list.sections[0].groups[0].sum, QuantitySum(value: 5, unitKey: "clove"))
    }

    func testKeptAsTextRowArrivesWithNilIngredientColumns() throws {
        try seedFixture()
        let recipeID = try store.save(makeDraft(rows: [
            makeRow("a splash of something", name: "a splash of something", ingredient: nil, keepAsText: true),
        ]))
        try store.setSelected(recipeID, true)
        let row = try XCTUnwrap(store.groceryListInput().rows.first)
        XCTAssertNil(row.ingredientID)
        XCTAssertNil(row.ingredientName)
        XCTAssertNil(row.category)
        XCTAssertEqual(row.name, "a splash of something")
    }

    // MARK: - Manual items (§9)

    func testManualItemsAddCheckDeleteAndBlankIsRefused() throws {
        let coffee = try store.addManualItem("  coffee ")
        let tea = try store.addManualItem("tea")
        XCTAssertThrowsError(try store.addManualItem("   ")) { error in
            XCTAssertEqual(error as? RecipeStoreError, .blankManualItem)
        }
        var items = try store.manualItems()
        XCTAssertEqual(items.map(\.id), [coffee, tea], "created order")
        XCTAssertEqual(items.map(\.text), ["coffee", "tea"], "trimmed")
        XCTAssertEqual(items.map(\.isChecked), [false, false])

        try store.setManualItemChecked(coffee, true)
        items = try store.manualItems()
        XCTAssertEqual(items.map(\.isChecked), [true, false])
        XCTAssertNotNil(items[0].checkedAt)
        try store.setManualItemChecked(coffee, false)
        XCTAssertEqual(try store.manualItems().map(\.isChecked), [false, false])

        try store.deleteManualItem(tea)
        XCTAssertEqual(try store.manualItems().map(\.id), [coffee])
        XCTAssertEqual(try store.groceryListInput().manualItems.map(\.id), [coffee],
                       "manual items ride along in the list snapshot")
    }

    func testClearCheckedRemovesChecksAndCheckedManualItemsOnly() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let (soup, _) = try saveSoupAndRisotto()
        try store.setSelected(soup, true)
        try store.setChecked(ingredientID: garlic, true)
        let coffee = try store.addManualItem("coffee")
        let tea = try store.addManualItem("tea")
        try store.setManualItemChecked(coffee, true)

        try store.clearChecked()

        let input = try store.groceryListInput()
        XCTAssertEqual(input.checkedIngredientIDs, [])
        XCTAssertEqual(input.manualItems.map(\.id), [tea], "the checked manual item is gone, the unchecked one stays")
        XCTAssertEqual(try store.selectedRecipeCount(), 1, "Clear checked leaves selection alone")
    }

    func testDoneShoppingClearsChecksCheckedManualItemsAndSelectionInOneCall() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let (soup, risotto) = try saveSoupAndRisotto()
        try store.setSelected(soup, true)
        try store.setSelected(risotto, true)
        try store.setChecked(ingredientID: garlic, true)
        let coffee = try store.addManualItem("coffee")
        let tea = try store.addManualItem("tea")
        try store.setManualItemChecked(coffee, true)

        try store.doneShopping()

        let input = try store.groceryListInput()
        XCTAssertEqual(input.rows, [], "no recipe is selected any more")
        XCTAssertEqual(input.checkedIngredientIDs, [])
        XCTAssertEqual(input.manualItems.map(\.id), [tea])
        XCTAssertEqual(try store.selectedRecipeCount(), 0)
        XCTAssertEqual(try store.count(inTable: "check_state"), 0)
        XCTAssertEqual(try store.recipes().count, 2, "Done shopping deselects; it never deletes recipes")
    }

    // MARK: - Snapshot & boundary

    func testSnapshotGivesTwoReadsOneState() throws {
        try seedFixture()
        _ = try saveSoupAndRisotto()
        let (recipes, count) = try store.snapshot { () throws -> ([Recipe], Int) in
            (try store.recipes(), try store.count(inTable: "recipes"))
        }
        XCTAssertEqual(recipes.count, count)
    }

    /// The `snapshot` contract at the store's altitude, mirroring the connection-
    /// level hammer in SQLiteDBTests: while the main actor saves two-row recipes, a
    /// background reader inside one `store.snapshot` must never observe half a save.
    func testSnapshotNeverObservesHalfASave() throws {
        try seedFixture()
        let garlic = try id("garlic")
        let onion = try id("onion")
        let store = try XCTUnwrap(self.store)
        let group = DispatchGroup()
        var inconsistencies = 0
        let lock = NSLock()

        DispatchQueue(label: "snapshot-reader").async(group: group) {
            for _ in 0..<200 {
                let observed = (try? store.snapshot { () throws -> (Int, Int) in
                    (try store.count(inTable: "recipe_ingredients"), try store.count(inTable: "recipe_ingredients"))
                }) ?? (0, 0)
                if observed.0 % 2 != 0 || observed.0 != observed.1 {
                    lock.lock(); inconsistencies += 1; lock.unlock()
                }
            }
        }

        for i in 0..<40 {
            try store.save(makeDraft(title: "Recipe \(i)", rows: [
                makeRow("1 clove garlic", name: "garlic", ingredient: .existing(garlic), quantity: 1, unitKey: "clove"),
                makeRow("1 onion", name: "onion", ingredient: .existing(onion), quantity: 1, lineIndex: 1),
            ]))
        }

        group.wait()
        XCTAssertEqual(inconsistencies, 0,
                       "a snapshot observed a torn save (odd row count, or two reads disagreeing)")
        XCTAssertEqual(try store.count(inTable: "recipe_ingredients"), 80, "every save must have committed cleanly")
    }

    /// The snapshot reads-only contract, including the Storage-internal escape route:
    /// a RAW writer (`insertIngredientRow`, which bypasses `db.transaction` because it
    /// runs inside `save`'s transaction) is rejected inside a snapshot at prepare
    /// time via `sqlite3_stmt_readonly`. The snapshot rolls back and the connection
    /// stays writable.
    func testRawStorageWriteInsideSnapshotIsRejected() throws {
        XCTAssertThrowsError(try store.snapshot {
            try store.insertIngredientRow(slug: "sneaky", canonicalName: "Sneaky", category: .other, isCustom: true)
        }) { error in
            XCTAssertTrue("\(error)".contains("snapshots are reads-only"),
                          "expected the reads-only diagnostic, got: \(error)")
        }
        XCTAssertNil(try store.ingredientID(slug: "sneaky"), "the rejected write must not have landed")
        try seedFixture()   // normal writes still work after the rolled-back snapshot
        XCTAssertEqual(try store.ingredientCount(), Self.fixture.count)
    }

    /// `@unchecked Sendable` and "one write path" both rest on the store having no
    /// state but the connection: no caches, no queued writes, nothing a view could
    /// reach around `save` to mutate. Pinned by reflection.
    func testStoreHasNoStateBeyondTheConnection() throws {
        let subject: RecipeStore = try XCTUnwrap(store)
        let children = Mirror(reflecting: subject).children.map { $0.label ?? "" }
        XCTAssertEqual(children, ["db"])
    }

    func testCountTakesABareTableIdentifier() throws {
        try seedFixture()
        XCTAssertEqual(try store.count(inTable: "ingredients"), Self.fixture.count)
        XCTAssertEqual(try store.count(inTable: "manual_items"), 0)
    }

    func testStringArrayEncodingRoundTripsAwkwardLines() {
        let lines = ["2 cups \"good\" broth", "½ tsp salt, or to taste", "", "line with \\ backslash", "emoji 🍋"]
        XCTAssertEqual(RecipeStore.decodeStringArray(RecipeStore.encodeStringArray(lines)), lines)
        XCTAssertEqual(RecipeStore.decodeStringArray(nil), [])
        XCTAssertEqual(RecipeStore.decodeStringArray("not json"), [])
        XCTAssertEqual(RecipeStore.encodeStringArray([]), "[]")
    }
}
