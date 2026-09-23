import XCTest
@testable import RecipeToGroceryList

/// `RecipesModel` over a real temp-file store seeded from the bundled library:
/// newest-first reload, the "cooking this" round trip, delete (and its lines
/// leaving the list — §9), rename, and the write hook. Recipes are one-row drafts
/// resolved with the registry's exact-name match and saved through
/// `RecipeStore.save`. `@MainActor` because the model and the store's writes are.
@MainActor
final class RecipesModelTests: XCTestCase {

    private var dbPath: String!
    private var store: RecipeStore!
    private var index: IngredientIndex!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "rtg-recipesmodel-\(UUID().uuidString).sqlite"
        store = RecipeStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
        try store.seedIngredientsIfNeeded(IngredientSeed.load(from: Bundle(for: Self.self)))
        index = try store.ingredientIndex()
    }

    override func tearDownWithError() throws {
        store = nil   // close the connection before deleting files
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    // MARK: - Fixtures

    /// One garlic row, so every recipe here contributes the same canonical and the
    /// list shows the merge.
    private func save(_ title: String, kind: SourceKind = .text, servings: String? = nil) throws -> Int64 {
        let garlic = try XCTUnwrap(index.exactMatch("Garlic"), "the bundled seed has Garlic")
        let row = DraftRow(lineIndex: 0,
                           rawLine: "3 cloves garlic",
                           name: "garlic",
                           quantity: 3,
                           unitKey: "clove",
                           unitText: "cloves",
                           ingredient: .existing(garlic),
                           ingredientName: "Garlic",
                           resolution: .exact)
        let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
        let source = RecipeSource(kind: kind,
                                  ref: kind == .url ? "https://example.com/recipes/\(slug)" : nil,
                                  servingsText: servings)
        return try store.save(RecipeDraft(title: title, source: source, rawLines: [row.rawLine], rows: [row]))
    }

    private func list() throws -> GroceryList {
        GroceryListBuilder.build(try store.groceryListInput())
    }

    // MARK: - Reload

    func testEmptyStoreIsEmpty() {
        let model = RecipesModel(store: store)
        XCTAssertTrue(model.isEmpty)
        model.reload()
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.recipes, [])
        XCTAssertNil(model.loadError)
    }

    func testReloadListsNewestFirstWithLineCounts() throws {
        let soup = try save("Lentil soup")
        let risotto = try save("Mushroom risotto", kind: .url, servings: "Serves 4")
        let model = RecipesModel(store: store)
        model.reload()

        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.recipes.map(\.id), [risotto, soup], "newest first")
        XCTAssertEqual(model.recipes.map(\.title), ["Mushroom risotto", "Lentil soup"])
        XCTAssertEqual(model.recipes.map(\.lineCount), [1, 1])
        XCTAssertEqual(model.recipes.map(\.sourceKind), [.url, .text])
        XCTAssertEqual(model.recipes.first?.servingsText, "Serves 4")
        XCTAssertEqual(model.recipes.first?.sourceRef, "https://example.com/recipes/mushroom-risotto")
        XCTAssertFalse(model.recipes.contains { $0.isSelected }, "a saved recipe starts unselected — cooking this is a separate tap")
        XCTAssertEqual(model.recipe(id: soup)?.title, "Lentil soup")
        XCTAssertNil(model.recipe(id: 987_654_321))
    }

    // MARK: - Selection (§9)

    func testSetSelectedRoundTripsAndPutsTheLinesOnTheList() throws {
        let id = try save("Lentil soup")
        var writes = 0
        let model = RecipesModel(store: store) { writes += 1 }
        model.reload()
        XCTAssertTrue(try list().isEmpty)

        let recipe = try XCTUnwrap(model.recipe(id: id))
        try model.setSelected(recipe, true)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.recipe(id: id)?.isSelected, true, "the model reloaded")
        XCTAssertEqual(try store.recipe(id: id)?.isSelected, true, "the store has it")
        XCTAssertEqual(try store.selectedRecipeCount(), 1)
        XCTAssertFalse(try list().isEmpty, "its lines are on the list")

        try model.setSelected(try XCTUnwrap(model.recipe(id: id)), false)
        XCTAssertEqual(writes, 2)
        XCTAssertEqual(model.recipe(id: id)?.isSelected, false)
        XCTAssertEqual(try store.selectedRecipeCount(), 0)
        XCTAssertTrue(try list().isEmpty)
    }

    func testSetSelectedOnAMissingRecipeThrowsWithoutAWrite() throws {
        let id = try save("Lentil soup")
        var writes = 0
        let model = RecipesModel(store: store) { writes += 1 }
        model.reload()
        let recipe = try XCTUnwrap(model.recipe(id: id))
        try store.deleteRecipe(id)   // gone underneath the model

        XCTAssertThrowsError(try model.setSelected(recipe, true)) { error in
            XCTAssertEqual(error as? RecipeStoreError, .unknownRecipe(id))
        }
        XCTAssertEqual(writes, 0, "a refused write never signals the app")
    }

    // MARK: - Delete

    func testDeleteRemovesTheRecipeAndItsLinesLeaveTheList() throws {
        let soup = try save("Lentil soup")
        let risotto = try save("Mushroom risotto")
        var writes = 0
        let model = RecipesModel(store: store) { writes += 1 }
        model.reload()
        try model.setSelected(try XCTUnwrap(model.recipe(id: soup)), true)
        try model.setSelected(try XCTUnwrap(model.recipe(id: risotto)), true)
        XCTAssertEqual(try list().sections.flatMap(\.groups).first?.lines.count, 2, "both contribute garlic")

        try model.delete(try XCTUnwrap(model.recipe(id: soup)))
        XCTAssertEqual(writes, 3)
        XCTAssertEqual(model.recipes.map(\.id), [risotto])
        XCTAssertNil(try store.recipe(id: soup))
        XCTAssertEqual(try store.recipeIngredients(recipeID: soup), [], "rows cascade")
        let garlic = try XCTUnwrap(list().sections.flatMap(\.groups).first)
        XCTAssertEqual(garlic.lines.map(\.recipeTitle), ["Mushroom risotto"], "the soup's line left the list")

        try model.delete(try XCTUnwrap(model.recipe(id: risotto)))
        XCTAssertEqual(writes, 4)
        XCTAssertTrue(model.isEmpty)
        XCTAssertTrue(try list().isEmpty)
    }

    func testDeletingTheLastContributorCollectsItsCheck() throws {
        let soup = try save("Lentil soup")
        let model = RecipesModel(store: store)
        model.reload()
        try model.setSelected(try XCTUnwrap(model.recipe(id: soup)), true)
        let garlic = try XCTUnwrap(index.exactMatch("Garlic"))
        try store.setChecked(ingredientID: garlic, true)
        XCTAssertEqual(try store.groceryListInput().checkedIngredientIDs, [garlic])

        try model.delete(try XCTUnwrap(model.recipe(id: soup)))
        XCTAssertEqual(try store.groceryListInput().checkedIngredientIDs, [], "the GC rode along with the delete (§9)")
    }

    func testDeletingAnAlreadyDeletedRecipeIsANoOp() throws {
        let soup = try save("Lentil soup")
        var writes = 0
        let model = RecipesModel(store: store) { writes += 1 }
        model.reload()
        let recipe = try XCTUnwrap(model.recipe(id: soup))
        try store.deleteRecipe(soup)
        // A double swipe must not surface an error (the store's contract).
        XCTAssertNoThrow(try model.delete(recipe))
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(model.isEmpty)
    }

    // MARK: - Rename

    func testRenamePersistsTrimmedAndLeavesRowsAlone() throws {
        let id = try save("Lentil soup")
        var writes = 0
        let model = RecipesModel(store: store) { writes += 1 }
        model.reload()
        let recipe = try XCTUnwrap(model.recipe(id: id))

        try model.rename(recipe, title: "  Red lentil soup  ")
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(model.recipe(id: id)?.title, "Red lentil soup")
        XCTAssertEqual(try store.recipe(id: id)?.title, "Red lentil soup")
        XCTAssertEqual(model.recipes.map(\.id), [id], "same identity")
        XCTAssertEqual(try store.recipeIngredients(recipeID: id).count, 1, "rows untouched")
        XCTAssertEqual(try store.recipe(id: id)?.rawLines, ["3 cloves garlic"])
    }

    func testRenameBlankThrowsAndWritesNothing() throws {
        let id = try save("Lentil soup")
        var writes = 0
        let model = RecipesModel(store: store) { writes += 1 }
        model.reload()
        let recipe = try XCTUnwrap(model.recipe(id: id))

        for blank in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try model.rename(recipe, title: blank), "\"\(blank)\" is blank") { error in
                XCTAssertEqual(error as? RecipeStoreError, .emptyName)
            }
        }
        XCTAssertEqual(writes, 0, "a refused write never signals the app")
        XCTAssertEqual(model.recipe(id: id)?.title, "Lentil soup")
        XCTAssertEqual(try store.recipe(id: id)?.title, "Lentil soup")
    }

    // MARK: - Write hook

    func testOnWriteIsCalledOncePerSuccessfulWriteAfterTheReload() throws {
        let id = try save("Lentil soup")
        var seen: [Bool?] = []
        var model: RecipesModel!
        // Recorded from inside the hook: the model has already reloaded by the time
        // the app is told.
        model = RecipesModel(store: store) { seen.append(model.recipe(id: id)?.isSelected) }
        model.reload()

        try model.setSelected(try XCTUnwrap(model.recipe(id: id)), true)
        try model.rename(try XCTUnwrap(model.recipe(id: id)), title: "Soup")
        try model.setSelected(try XCTUnwrap(model.recipe(id: id)), false)
        try model.delete(try XCTUnwrap(model.recipe(id: id)))
        XCTAssertEqual(seen, [true, true, false, nil])
    }
}
