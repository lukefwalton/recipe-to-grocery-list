import XCTest
@testable import RecipeToGroceryList

/// The list as a pure function (spec §8 sums, §9 ordering and membership). No
/// database: `GroceryListInput` values go in, a `GroceryList` comes out.
final class GroceryListTests: XCTestCase {

    // MARK: - Builders

    private func row(_ id: Int64,
                     recipe: Int64 = 1,
                     title: String = "Lentil soup",
                     ingredient: Int64? = nil,
                     ingredientName: String? = nil,
                     category: IngredientCategory? = nil,
                     name: String,
                     quantity: Double? = nil,
                     unitKey: String? = nil,
                     unitText: String? = nil,
                     note: String? = nil,
                     sortOrder: Int = 0) -> SelectedRow {
        SelectedRow(rowID: id,
                    recipeID: recipe,
                    recipeTitle: title,
                    ingredientID: ingredient,
                    ingredientName: ingredientName,
                    category: category,
                    name: name,
                    quantity: quantity,
                    unitKey: unitKey,
                    unitText: unitText,
                    note: note,
                    sortOrder: sortOrder)
    }

    private func manualItem(_ id: Int64, _ text: String, checked: Bool = false) -> ManualItem {
        ManualItem(id: id,
                   text: text,
                   checkedAt: checked ? Date(timeIntervalSince1970: 1_000) : nil,
                   createdAt: Date(timeIntervalSince1970: Double(id)))
    }

    private func line(_ id: Int64, quantity: Double?, unitKey: String?) -> GroceryLine {
        GroceryLine(id: id, recipeTitle: "R", name: "x", quantity: quantity, unitKey: unitKey, unitText: nil, note: nil)
    }

    private func build(_ rows: [SelectedRow], manualItems: [ManualItem] = [], checked: Set<Int64> = []) -> GroceryList {
        GroceryListBuilder.build(GroceryListInput(rows: rows, manualItems: manualItems, checkedIngredientIDs: checked))
    }

    // Ingredient ids used across tests.
    private let garlic: Int64 = 10, onion: Int64 = 11, carrot: Int64 = 12, parsley: Int64 = 13
    private let butter: Int64 = 20, flour: Int64 = 30, broth: Int64 = 31, salt: Int64 = 40

    // MARK: - Empty

    func testEmptyInputIsEmpty() {
        let list = GroceryListBuilder.build(.empty)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(list.sections, [])
        XCTAssertEqual(list.uncheckedCount, 0)
        XCTAssertEqual(list.checkedCount, 0)
    }

    // MARK: - Sections

    func testSectionsFollowStoreOrderAndOnlyNonEmptyOnesAppear() {
        let list = build([
            row(1, ingredient: flour, ingredientName: "Flour", category: .pantry, name: "flour"),
            row(2, ingredient: onion, ingredientName: "Onion", category: .produce, name: "onion"),
            row(3, ingredient: butter, ingredientName: "Butter", category: .dairy, name: "butter"),
            row(4, name: "a splash of something"),
        ])
        XCTAssertEqual(list.sections.map(\.category), [.produce, .dairy, .pantry, .other],
                       "produce, bakery, dairy, meat, seafood, frozen, pantry, other — empties skipped")
        XCTAssertEqual(list.sections.map(\.id), list.sections.map(\.category))
        XCTAssertFalse(list.isEmpty)
    }

    func testOtherSectionAppearsForTextRowsOrManualItemsAlone() {
        XCTAssertEqual(build([row(1, name: "a splash of something")]).sections.map(\.category), [.other])
        XCTAssertEqual(build([], manualItems: [manualItem(1, "coffee")]).sections.map(\.category), [.other])
    }

    // MARK: - Groups

    func testRowsGroupByIngredientAndLinesKeepInputOrder() {
        let list = build([
            row(1, recipe: 1, title: "Lentil soup", ingredient: garlic, ingredientName: "Garlic", category: .produce, name: "garlic", quantity: 3, unitKey: "clove"),
            row(2, recipe: 1, title: "Lentil soup", ingredient: onion, ingredientName: "Onion", category: .produce, name: "onion", quantity: 1),
            row(3, recipe: 2, title: "Risotto", ingredient: garlic, ingredientName: "Garlic", category: .produce, name: "garlic cloves", quantity: 2, unitKey: "clove"),
        ])
        let produce = list.sections[0]
        XCTAssertEqual(produce.groups.map(\.id), [garlic, onion], "one heading per canonical ingredient")
        XCTAssertEqual(produce.groups.map(\.name), ["Garlic", "Onion"])
        XCTAssertEqual(produce.groups[0].lines.map(\.id), [1, 3], "lines keep recipe order")
        XCTAssertEqual(produce.groups[0].lines.map(\.recipeTitle), ["Lentil soup", "Risotto"])
        XCTAssertEqual(produce.groups[0].lines.map(\.name), ["garlic", "garlic cloves"], "the name as written survives")
        XCTAssertEqual(produce.otherItems, [], "only Other carries otherItems")
    }

    func testUncheckedGroupsComeBeforeCheckedWithinACategory() {
        let rows = [
            row(1, ingredient: onion, ingredientName: "Onion", category: .produce, name: "onion"),
            row(2, ingredient: carrot, ingredientName: "Carrot", category: .produce, name: "carrot"),
            row(3, ingredient: garlic, ingredientName: "Garlic", category: .produce, name: "garlic"),
        ]
        XCTAssertEqual(build(rows).sections[0].groups.map(\.name), ["Carrot", "Garlic", "Onion"])
        XCTAssertEqual(build(rows, checked: [onion]).sections[0].groups.map(\.name), ["Carrot", "Garlic", "Onion"])
        XCTAssertEqual(build(rows, checked: [carrot]).sections[0].groups.map(\.name), ["Garlic", "Onion", "Carrot"],
                       "a checked heading sinks to the bottom of its category, not out of view")
        XCTAssertEqual(build(rows, checked: [carrot, onion]).sections[0].groups.map(\.name), ["Garlic", "Carrot", "Onion"],
                       "checked headings are name-sorted among themselves")
        XCTAssertEqual(build(rows, checked: [carrot]).sections[0].groups.map(\.isChecked), [false, false, true])
    }

    func testGroupsSortByNameCaseInsensitively() {
        let list = build([
            row(1, ingredient: 1, ingredientName: "cherry", category: .produce, name: "cherry"),
            row(2, ingredient: 2, ingredientName: "Banana", category: .produce, name: "banana"),
            row(3, ingredient: 3, ingredientName: "apple", category: .produce, name: "apple"),
        ])
        XCTAssertEqual(list.sections[0].groups.map(\.name), ["apple", "Banana", "cherry"],
                       "NOCASE — a case-sensitive sort would put Banana first")
    }

    func testCheckedFlagComesFromCheckState() {
        let rows = [row(1, ingredient: garlic, ingredientName: "Garlic", category: .produce, name: "garlic")]
        XCTAssertEqual(build(rows).sections[0].groups[0].isChecked, false)
        XCTAssertEqual(build(rows, checked: [garlic]).sections[0].groups[0].isChecked, true)
        XCTAssertEqual(build(rows, checked: [999]).sections[0].groups[0].isChecked, false, "a stale id checks nothing")
    }

    func testMissingJoinColumnsFallBackToTheRowName() {
        // The store always fills these when the id is present; a hand-built row
        // must still land somewhere sensible rather than crash or vanish.
        let list = build([row(1, ingredient: garlic, name: "garlic")])
        XCTAssertEqual(list.sections.map(\.category), [.other])
        XCTAssertEqual(list.sections[0].groups.map(\.name), ["garlic"])
    }

    // MARK: - Sums (§8)

    func testSumWhenEveryLineHasAQuantityAndTheSameUnitKey() {
        let sum = GroceryListBuilder.sum(of: [line(1, quantity: 3, unitKey: "clove"), line(2, quantity: 2, unitKey: "clove")])
        XCTAssertEqual(sum, QuantitySum(value: 5, unitKey: "clove"))
        XCTAssertEqual(sum?.text, "5 cloves")
    }

    func testSumTreatsNilUnitKeysAsTheSameUnit() {
        let sum = GroceryListBuilder.sum(of: [line(1, quantity: 2, unitKey: nil), line(2, quantity: 1, unitKey: nil)])
        XCTAssertEqual(sum, QuantitySum(value: 3, unitKey: nil), "\"2 onions\" + \"1 onion\" → 3")
        XCTAssertEqual(sum?.text, "3")
    }

    func testNoSumAcrossUnitKeys() {
        XCTAssertNil(GroceryListBuilder.sum(of: [line(1, quantity: 2, unitKey: "cup"), line(2, quantity: 500, unitKey: "ml")]),
                     "never converts, never sums cups with millilitres")
        XCTAssertNil(GroceryListBuilder.sum(of: [line(1, quantity: 2, unitKey: "cup"), line(2, quantity: 1, unitKey: nil)]),
                     "a unit and no unit are different keys")
    }

    func testNoSumWhenAnyLineLacksAQuantity() {
        XCTAssertNil(GroceryListBuilder.sum(of: [line(1, quantity: 2, unitKey: "cup"), line(2, quantity: nil, unitKey: "cup")]))
        XCTAssertNil(GroceryListBuilder.sum(of: [line(1, quantity: nil, unitKey: nil), line(2, quantity: nil, unitKey: nil)]))
        XCTAssertNil(GroceryListBuilder.sum(of: [line(1, quantity: 2, unitKey: "cup"), line(2, quantity: .infinity, unitKey: "cup")]))
    }

    func testSingleLineHasNoSum() {
        XCTAssertNil(GroceryListBuilder.sum(of: [line(1, quantity: 2, unitKey: "cup")]))
        XCTAssertNil(GroceryListBuilder.sum(of: []))
    }

    func testBuildAttachesSumsPerGroup() {
        let list = build([
            row(1, recipe: 1, ingredient: garlic, ingredientName: "Garlic", category: .produce, name: "garlic", quantity: 3, unitKey: "clove"),
            row(2, recipe: 2, ingredient: garlic, ingredientName: "Garlic", category: .produce, name: "garlic", quantity: 2, unitKey: "clove"),
            row(3, recipe: 1, ingredient: broth, ingredientName: "Vegetable broth", category: .pantry, name: "broth", quantity: 2, unitKey: "cup"),
            row(4, recipe: 2, ingredient: broth, ingredientName: "Vegetable broth", category: .pantry, name: "stock", quantity: 500, unitKey: "ml"),
            row(5, recipe: 1, ingredient: parsley, ingredientName: "Parsley", category: .produce, name: "parsley"),
        ])
        let produce = list.sections[0], pantry = list.sections[1]
        XCTAssertEqual(produce.groups.map(\.name), ["Garlic", "Parsley"])
        XCTAssertEqual(produce.groups[0].sum, QuantitySum(value: 5, unitKey: "clove"))
        XCTAssertNil(produce.groups[1].sum, "one line, no quantity → no sum")
        XCTAssertNil(pantry.groups[0].sum, "cups + ml → no sum")
    }

    // MARK: - Other (§9)

    func testOtherSectionCompositionAndOrder() {
        let list = build([
            row(1, ingredient: salt, ingredientName: "Salt", category: .other, name: "salt"),
            row(2, name: "a splash of something"),
            row(3, name: "love"),
        ], manualItems: [
            manualItem(1, "coffee", checked: true),
            manualItem(2, "tea"),
            manualItem(3, "milk"),
        ])
        let other = list.sections[0]
        XCTAssertEqual(other.category, .other)
        XCTAssertEqual(other.groups.map(\.name), ["Salt"], ".other-category groups first")
        XCTAssertEqual(other.otherItems.map(\.id), ["text-2", "text-3", "manual-2", "manual-3", "manual-1"],
                       "kept-as-text rows in input order, then manual items unchecked before checked, each in created order")
        XCTAssertEqual(other.otherItems.map(\.isChecked), [false, false, false, false, true])
    }

    func testTextRowsAreNeverMerged() {
        let list = build([row(1, name: "a pinch of magic"), row(2, name: "a pinch of magic")])
        XCTAssertEqual(list.sections[0].otherItems.count, 2, "no ingredient, no grouping — two separate text items")
        XCTAssertEqual(list.sections[0].groups, [])
    }

    func testOtherItemPayloads() {
        let list = build([row(9, name: "a splash of something", quantity: 1, unitKey: "cup")],
                         manualItems: [manualItem(4, "coffee", checked: true)])
        guard case .text(let textLine)? = list.sections[0].otherItems.first else { return XCTFail("expected a text item") }
        XCTAssertEqual(textLine.id, 9)
        XCTAssertEqual(textLine.name, "a splash of something")
        XCTAssertEqual(textLine.amountText, "1 cup")
        guard case .manual(let item)? = list.sections[0].otherItems.last else { return XCTFail("expected a manual item") }
        XCTAssertEqual(item.text, "coffee")
        XCTAssertTrue(item.isChecked)
    }

    // MARK: - Counts & display

    func testCountsCoverGroupsTextRowsAndManualItems() {
        let list = build([
            row(1, ingredient: garlic, ingredientName: "Garlic", category: .produce, name: "garlic"),
            row(2, ingredient: onion, ingredientName: "Onion", category: .produce, name: "onion"),
            row(3, name: "a splash of something"),
        ], manualItems: [
            manualItem(1, "coffee", checked: true),
            manualItem(2, "tea"),
        ], checked: [garlic])
        XCTAssertEqual(list.uncheckedCount, 3, "Onion + the text row + tea")
        XCTAssertEqual(list.checkedCount, 2, "Garlic + coffee")
        XCTAssertFalse(list.isEmpty)
    }

    func testAmountTextFormatsThroughQuantityFormat() {
        XCTAssertEqual(GroceryLine(id: 1, recipeTitle: "R", name: "broth", quantity: 2, unitKey: "cup", unitText: "cups", note: nil).amountText, "2 cups")
        XCTAssertEqual(GroceryLine(id: 2, recipeTitle: "R", name: "salt", quantity: 0.5, unitKey: "tsp", unitText: "tsp", note: nil).amountText, "½ tsp")
        XCTAssertEqual(GroceryLine(id: 3, recipeTitle: "R", name: "onion", quantity: 3, unitKey: nil, unitText: nil, note: nil).amountText, "3")
        XCTAssertEqual(GroceryLine(id: 4, recipeTitle: "R", name: "parsley", quantity: nil, unitKey: nil, unitText: nil, note: nil).amountText, "",
                       "no quantity given → nothing to show")
    }
}
