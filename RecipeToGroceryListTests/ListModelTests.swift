import XCTest
@testable import RecipeToGroceryList

/// `ListModel` over a real temp-file store seeded from the bundled library: the
/// list as the model sees it (§8 sums, §9 check-off, survival and GC, manual items,
/// Done shopping) and the write hook that fans a change out to the rest of the app.
/// Recipes are hand-built `RecipeDraft`s resolved with the registry's exact-name
/// match, the way `ScreenshotDemoSeeder` and the Confirm screen hand them over, and
/// saved through `RecipeStore.save` — the one write path. `@MainActor` because the
/// model and the store's writes are.
@MainActor
final class ListModelTests: XCTestCase {

    private var dbPath: String!
    private var store: RecipeStore!
    private var index: IngredientIndex!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "rtg-listmodel-\(UUID().uuidString).sqlite"
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

    /// A row resolved against the real seed: `.existing(id)` from the layer-0 match,
    /// resolution `.exact`, exactly what the validator requires of a row with an
    /// ingredient.
    private func row(_ rawLine: String,
                     name: String,
                     canonical: String,
                     quantity: Double? = nil,
                     unitKey: String? = nil,
                     unitText: String? = nil,
                     lineIndex: Int) throws -> DraftRow {
        let id = try XCTUnwrap(index.exactMatch(canonical), "the bundled seed has \(canonical)")
        return DraftRow(lineIndex: lineIndex,
                        rawLine: rawLine,
                        name: name,
                        quantity: quantity,
                        unitKey: unitKey,
                        unitText: unitText,
                        ingredient: .existing(id),
                        ingredientName: canonical,
                        resolution: .exact)
    }

    private func draft(title: String, rows: [DraftRow]) -> RecipeDraft {
        RecipeDraft(title: title,
                    source: RecipeSource(kind: .text),
                    rawLines: rows.map(\.rawLine),
                    rows: rows)
    }

    /// Garlic in cloves, an onion with no unit, broth in cups.
    private func saveSoup() throws -> Int64 {
        let rows: [DraftRow] = try [
            row("3 cloves garlic", name: "garlic", canonical: "Garlic",
                quantity: 3, unitKey: "clove", unitText: "cloves", lineIndex: 0),
            row("1 onion", name: "onion", canonical: "Onion", quantity: 1, lineIndex: 1),
            row("4 cups vegetable broth", name: "vegetable broth", canonical: "Vegetable broth",
                quantity: 4, unitKey: "cup", unitText: "cups", lineIndex: 2),
        ]
        return try store.save(draft(title: "Lentil soup", rows: rows))
    }

    /// Shares all three with the soup: garlic in cloves (sums), an onion with no unit
    /// (nil == nil sums), broth in millilitres (never summed with cups).
    private func saveRisotto() throws -> Int64 {
        let rows: [DraftRow] = try [
            row("2 cloves garlic", name: "garlic", canonical: "Garlic",
                quantity: 2, unitKey: "clove", unitText: "cloves", lineIndex: 0),
            row("1 onion", name: "onion", canonical: "Onion", quantity: 1, lineIndex: 1),
            row("500 ml vegetable broth", name: "vegetable broth", canonical: "Vegetable broth",
                quantity: 500, unitKey: "ml", unitText: "ml", lineIndex: 2),
        ]
        return try store.save(draft(title: "Mushroom risotto", rows: rows))
    }

    /// Both saved and both "cooking this".
    private func selectSoupAndRisotto() throws -> (soup: Int64, risotto: Int64) {
        let soup = try saveSoup()
        let risotto = try saveRisotto()
        try store.setSelected(soup, true)
        try store.setSelected(risotto, true)
        return (soup, risotto)
    }

    private func allGroups(_ model: ListModel) -> [IngredientGroup] {
        model.list.sections.flatMap(\.groups)
    }

    private func group(named name: String, in model: ListModel) -> IngredientGroup? {
        allGroups(model).first { $0.name == name }
    }

    private func section(containing groupID: Int64, in model: ListModel) -> GrocerySection? {
        model.list.sections.first { section in section.groups.contains { $0.id == groupID } }
    }

    private func manualItems(in model: ListModel) -> [ManualItem] {
        model.list.sections.flatMap(\.otherItems).compactMap { item -> ManualItem? in
            if case .manual(let manual) = item { return manual }
            return nil
        }
    }

    private func checkedIngredientIDs() throws -> Set<Int64> {
        try store.groceryListInput().checkedIngredientIDs
    }

    // MARK: - Empty

    func testEmptyStoreIsEmpty() {
        let model = ListModel(store: store)
        XCTAssertTrue(model.isEmpty, "before the first reload the list is the empty build")
        model.reload()
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.hasChecked)
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.list.sections, [])
        XCTAssertEqual(model.list.uncheckedCount, 0)
        XCTAssertEqual(model.list.checkedCount, 0)
    }

    func testSavedButUnselectedRecipesContributeNothing() throws {
        _ = try saveSoup()
        let model = ListModel(store: store)
        model.reload()
        XCTAssertTrue(model.isEmpty, "membership is selection, not existence (§9)")
    }

    // MARK: - Merge and sums (§8)

    func testSelectedRecipesMergeByCanonicalIngredientWithHonestSums() throws {
        _ = try selectSoupAndRisotto()
        let model = ListModel(store: store)
        model.reload()

        XCTAssertFalse(model.isEmpty)
        XCTAssertNil(model.loadError)

        let garlic = try XCTUnwrap(group(named: "Garlic", in: model))
        XCTAssertEqual(allGroups(model).filter { $0.id == garlic.id }.count, 1, "one heading per canonical")
        XCTAssertEqual(garlic.lines.count, 2)
        XCTAssertEqual(garlic.lines.map(\.recipeTitle), ["Lentil soup", "Mushroom risotto"],
                       "lines keep recipe order: the soup was saved first")
        XCTAssertEqual(garlic.lines.map(\.amountText), ["3 cloves", "2 cloves"])
        XCTAssertEqual(garlic.sum?.text, "5 cloves", "same unit key on every line → a total")
        XCTAssertFalse(garlic.isChecked)

        let onion = try XCTUnwrap(group(named: "Onion", in: model))
        XCTAssertEqual(onion.lines.count, 2)
        XCTAssertEqual(onion.sum?.text, "2", "two nil unit keys count as the same unit")

        let broth = try XCTUnwrap(group(named: "Vegetable broth", in: model))
        XCTAssertEqual(broth.lines.map(\.amountText), ["4 cups", "500 ml"])
        XCTAssertNil(broth.sum, "cups are never added to millilitres")

        XCTAssertEqual(allGroups(model).count, 3)
        XCTAssertEqual(model.list.uncheckedCount, 3)
        XCTAssertEqual(model.list.checkedCount, 0)
        XCTAssertFalse(model.hasChecked)

        // Sections follow the seed's categories in store order, empties skipped.
        let categories = Set(allGroups(model).map(\.category))
        XCTAssertEqual(model.list.sections.map(\.category),
                       IngredientCategory.storeOrder.filter { categories.contains($0) })
        XCTAssertEqual(section(containing: garlic.id, in: model)?.category,
                       index.entry(id: garlic.id)?.category)
    }

    // MARK: - Check-off (§9)

    func testToggleChecksTheHeadingAndSinksItToTheBottomOfItsSection() throws {
        _ = try selectSoupAndRisotto()
        var writes = 0
        let model = ListModel(store: store) { writes += 1 }
        model.reload()

        let garlic = try XCTUnwrap(group(named: "Garlic", in: model))
        let before = try XCTUnwrap(section(containing: garlic.id, in: model))
        XCTAssertEqual(before.groups.first?.id, garlic.id, "Garlic sorts before Onion while unchecked")

        try model.toggle(group: garlic)
        XCTAssertEqual(writes, 1)

        let checked = try XCTUnwrap(group(named: "Garlic", in: model))
        XCTAssertTrue(checked.isChecked)
        XCTAssertEqual(checked.lines.count, 2, "checking a heading checks it across every contributing recipe")
        XCTAssertTrue(model.hasChecked)
        XCTAssertEqual(model.list.checkedCount, 1)
        XCTAssertEqual(model.list.uncheckedCount, 2)

        let after = try XCTUnwrap(section(containing: garlic.id, in: model))
        XCTAssertEqual(after.groups.last?.id, garlic.id, "checked headings sink to the bottom of their category, not out of view")
        XCTAssertEqual(after.groups.first?.name, "Onion")
        XCTAssertEqual(try checkedIngredientIDs(), [garlic.id], "persisted on the ingredient")

        try model.toggle(group: checked)
        XCTAssertEqual(writes, 2)
        let unchecked = try XCTUnwrap(group(named: "Garlic", in: model))
        XCTAssertFalse(unchecked.isChecked)
        XCTAssertFalse(model.hasChecked)
        XCTAssertEqual(try checkedIngredientIDs(), [])
        XCTAssertEqual(try XCTUnwrap(section(containing: garlic.id, in: model)).groups.first?.id, garlic.id,
                       "back to name order once unchecked")
    }

    func testCheckSurvivesWhileAnotherSelectedRecipeContributesAndIsCollectedAfter() throws {
        let ids = try selectSoupAndRisotto()
        let model = ListModel(store: store)
        model.reload()
        let garlic = try XCTUnwrap(group(named: "Garlic", in: model))
        try model.toggle(group: garlic)

        // Deselect the soup: the risotto still needs garlic, so the check stays.
        try store.setSelected(ids.soup, false)
        model.reload()
        let survivor = try XCTUnwrap(group(named: "Garlic", in: model))
        XCTAssertTrue(survivor.isChecked, "check state lives on the ingredient, not the line")
        XCTAssertEqual(survivor.lines.map(\.recipeTitle), ["Mushroom risotto"])
        XCTAssertNil(survivor.sum, "a single line shows no total")
        XCTAssertEqual(model.list.checkedCount, 1)

        // Deselect the risotto: nothing contributes garlic, so the GC in the same
        // transaction removes the check row.
        try store.setSelected(ids.risotto, false)
        model.reload()
        XCTAssertTrue(model.isEmpty)
        XCTAssertFalse(model.hasChecked)
        XCTAssertEqual(try checkedIngredientIDs(), [], "GC ran with the deselect")

        // Re-selecting next week shows no stale check.
        try store.setSelected(ids.soup, true)
        model.reload()
        let fresh = try XCTUnwrap(group(named: "Garlic", in: model))
        XCTAssertFalse(fresh.isChecked)
    }

    func testToggleOnAnUnknownIngredientThrowsWithoutAWrite() throws {
        var writes = 0
        let model = ListModel(store: store) { writes += 1 }
        model.reload()
        let ghost = IngredientGroup(id: 987_654_321, name: "Ghost", category: .other,
                                    lines: [], isChecked: false, sum: nil)
        XCTAssertThrowsError(try model.toggle(group: ghost)) { error in
            XCTAssertEqual(error as? RecipeStoreError, .unknownIngredient(ghost.id))
        }
        XCTAssertEqual(writes, 0, "a refused write never signals the app")
        XCTAssertTrue(model.isEmpty)
    }

    // MARK: - Manual items (§9)

    func testManualItemsAreAddedToggledAndDeletedUnderOther() throws {
        var writes = 0
        let model = ListModel(store: store) { writes += 1 }
        model.reload()

        try model.addManual("  Coffee  ")
        XCTAssertEqual(writes, 1)
        XCTAssertFalse(model.isEmpty, "a manual item alone makes a list")
        XCTAssertEqual(model.list.sections.map(\.category), [.other])
        XCTAssertTrue(model.list.sections.first?.groups.isEmpty ?? false, "manual items are never merged into a heading")
        XCTAssertEqual(model.list.uncheckedCount, 1)

        let coffee = try XCTUnwrap(manualItems(in: model).first)
        XCTAssertEqual(coffee.text, "Coffee", "trimmed")
        XCTAssertFalse(coffee.isChecked)

        try model.toggleManual(coffee)
        XCTAssertEqual(writes, 2)
        let checked = try XCTUnwrap(manualItems(in: model).first)
        XCTAssertTrue(checked.isChecked)
        XCTAssertTrue(model.hasChecked)
        XCTAssertEqual(model.list.checkedCount, 1)
        XCTAssertEqual(model.list.uncheckedCount, 0)
        XCTAssertEqual(try checkedIngredientIDs(), [], "a manual check is not an ingredient check")

        try model.toggleManual(checked)
        XCTAssertEqual(writes, 3)
        XCTAssertFalse(try XCTUnwrap(manualItems(in: model).first).isChecked)
        XCTAssertFalse(model.hasChecked)

        try model.deleteManual(coffee)
        XCTAssertEqual(writes, 4)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(try store.manualItems(), [])
    }

    func testCheckedManualItemsSinkBelowUncheckedOnes() throws {
        let model = ListModel(store: store)
        model.reload()
        try model.addManual("Coffee")
        try model.addManual("Bread")
        XCTAssertEqual(manualItems(in: model).map(\.text), ["Coffee", "Bread"], "created order")

        let coffee = try XCTUnwrap(manualItems(in: model).first { $0.text == "Coffee" })
        try model.toggleManual(coffee)
        XCTAssertEqual(manualItems(in: model).map(\.text), ["Bread", "Coffee"], "unchecked before checked")
        XCTAssertEqual(manualItems(in: model).map(\.isChecked), [false, true])
    }

    func testBlankManualItemIsIgnoredWithoutAWrite() throws {
        var writes = 0
        let model = ListModel(store: store) { writes += 1 }
        model.reload()
        try model.addManual("   \n\t ")
        try model.addManual("")
        XCTAssertEqual(writes, 0, "an empty return on the Add field is a no-op, not an error")
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(try store.manualItems(), [])
    }

    // MARK: - Done shopping (§9)

    func testDoneShoppingClearsChecksDeselectsEveryRecipeAndDropsCheckedManualItems() throws {
        _ = try selectSoupAndRisotto()
        var writes = 0
        let model = ListModel(store: store) { writes += 1 }
        model.reload()
        try model.addManual("Coffee")
        try model.addManual("Bread")
        let garlic = try XCTUnwrap(group(named: "Garlic", in: model))
        try model.toggle(group: garlic)
        let coffee = try XCTUnwrap(manualItems(in: model).first { $0.text == "Coffee" })
        try model.toggleManual(coffee)
        let bread = try XCTUnwrap(manualItems(in: model).first { $0.text == "Bread" })
        try model.toggleManual(bread)
        XCTAssertEqual(writes, 5)
        XCTAssertEqual(model.list.checkedCount, 3)

        try model.doneShopping()
        XCTAssertEqual(writes, 6, "one write, one signal")

        XCTAssertTrue(model.isEmpty, "no selected recipes, no manual items left")
        XCTAssertFalse(model.hasChecked)
        XCTAssertEqual(try store.selectedRecipeCount(), 0)
        XCTAssertEqual(try store.recipes().count, 2, "nothing is deleted — the recipes are only deselected")
        XCTAssertEqual(try checkedIngredientIDs(), [])
        XCTAssertEqual(try store.manualItems(), [])
    }

    func testDoneShoppingKeepsUncheckedManualItems() throws {
        _ = try selectSoupAndRisotto()
        let model = ListModel(store: store)
        model.reload()
        try model.addManual("Coffee")
        try model.addManual("Bread")
        let coffee = try XCTUnwrap(manualItems(in: model).first { $0.text == "Coffee" })
        try model.toggleManual(coffee)

        try model.doneShopping()

        XCTAssertFalse(model.isEmpty, "an unchecked manual item is still something to buy")
        XCTAssertEqual(model.list.sections.map(\.category), [.other])
        XCTAssertEqual(allGroups(model), [], "every recipe was deselected")
        XCTAssertEqual(manualItems(in: model).map(\.text), ["Bread"])
        XCTAssertEqual(model.list.uncheckedCount, 1)
        XCTAssertEqual(model.list.checkedCount, 0)
    }

    // MARK: - Write hook

    func testOnWriteIsCalledOncePerSuccessfulWriteAndReloadsFirst() throws {
        _ = try selectSoupAndRisotto()
        var seen: [Int] = []
        var model: ListModel!
        // Recorded from inside the hook: the model has already rebuilt by the time
        // the app is told, so the screen that called it never shows a stale list.
        model = ListModel(store: store) { seen.append(model.list.checkedCount) }
        model.reload()

        let garlic = try XCTUnwrap(group(named: "Garlic", in: model))
        try model.toggle(group: garlic)                       // 1 checked
        try model.addManual("Coffee")                         // still 1
        let coffee = try XCTUnwrap(manualItems(in: model).first)
        try model.toggleManual(coffee)                        // 2
        try model.deleteManual(coffee)                        // 1
        try model.doneShopping()                              // 0
        XCTAssertEqual(seen, [1, 1, 2, 1, 0])
    }
}
