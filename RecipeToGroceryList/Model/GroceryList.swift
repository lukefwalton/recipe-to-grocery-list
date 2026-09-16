import Foundation

// The grocery list is a PURE FUNCTION of (selected recipes' rows, manual items,
// check state) — spec §9. `RecipeStore.groceryListInput()` reads those three in one
// snapshot; `GroceryListBuilder.build` turns them into sections with no database
// access, no cached rows, and no hidden list state. Rebuilt on every read; it is a
// few hundred rows at most. Being a value type is also the seam for a v1.1
// Reminders export.

/// One recipe line under an ingredient heading: "2 cups — Lentil soup".
struct GroceryLine: Equatable, Identifiable, Sendable {
    /// The `recipe_ingredients` row id.
    let id: Int64
    let recipeTitle: String
    /// The name as written on the recipe ("veggie broth"), shown for kept-as-text
    /// rows and available for a "matched as" detail under a heading.
    let name: String
    let quantity: Double?
    let unitKey: String?
    let unitText: String?
    let note: String?

    /// "2 cups", "½ tsp", "3", or "" when the line gave no amount (§8 shows "— Lentil
    /// soup" with a "no quantity given" hint).
    var amountText: String {
        QuantityFormat.string(quantity: quantity, unitKey: unitKey, unitText: unitText)
    }
}

/// The honest total to the right of a heading's lines (§8): only exists when every
/// line had a quantity and they all share one unit key.
struct QuantitySum: Equatable, Sendable {
    let value: Double
    let unitKey: String?

    var text: String { QuantityFormat.string(quantity: value, unitKey: unitKey) }
}

/// One canonical ingredient on the list: the checkable unit (§9). Lines keep recipe
/// order; `isChecked` comes from `check_state`, so it survives regeneration.
struct IngredientGroup: Equatable, Identifiable, Sendable {
    /// The ingredient id.
    let id: Int64
    let name: String
    let category: IngredientCategory
    var lines: [GroceryLine]
    var isChecked: Bool
    var sum: QuantitySum?
}

/// What lands under **Other** besides `.other`-category groups: rows the user kept as
/// text (never mergeable, never checkable — there is no ingredient to key a check
/// on) and manual items (checked individually).
enum OtherItem: Equatable, Identifiable, Sendable {
    case text(GroceryLine)
    case manual(ManualItem)

    var id: String {
        switch self {
        case .text(let line): return "text-\(line.id)"
        case .manual(let item): return "manual-\(item.id)"
        }
    }

    var isChecked: Bool {
        switch self {
        case .text: return false
        case .manual(let item): return item.isChecked
        }
    }
}

/// One category section in store order. `otherItems` is only ever non-empty for
/// `.other`.
struct GrocerySection: Equatable, Identifiable, Sendable {
    let category: IngredientCategory
    var groups: [IngredientGroup]
    var otherItems: [OtherItem]

    var id: IngredientCategory { category }
}

/// The whole list. `isEmpty` drives the `LFWEmptyState` deep link to Recipes; the
/// counts feed the "N left" chrome. Kept-as-text rows count as unchecked items
/// (they are things to buy) and never as checked.
struct GroceryList: Equatable, Sendable {
    var sections: [GrocerySection]
    var isEmpty: Bool
    var uncheckedCount: Int
    var checkedCount: Int
}

enum GroceryListBuilder {
    /// Ordering (§9): sections in `IngredientCategory.storeOrder`, only non-empty
    /// ones; inside a section, unchecked groups first, then checked — each run
    /// sorted by name case-insensitively (ties by id), so a checked heading sinks
    /// to the bottom of its category rather than out of view. Lines inside a group
    /// keep input order (recipe order, then `sort_order`). Under Other: `.other`
    /// groups, then kept-as-text rows in input order, then manual items — unchecked
    /// before checked, each in created order.
    static func build(_ input: GroceryListInput) -> GroceryList {
        var groupsByID: [Int64: IngredientGroup] = [:]
        var groupOrder: [Int64] = []
        var textLines: [GroceryLine] = []

        for row in input.rows {
            let line = GroceryLine(id: row.rowID,
                                   recipeTitle: row.recipeTitle,
                                   name: row.name,
                                   quantity: row.quantity,
                                   unitKey: row.unitKey,
                                   unitText: row.unitText,
                                   note: row.note)
            guard let ingredientID = row.ingredientID else {
                textLines.append(line)
                continue
            }
            if var group = groupsByID[ingredientID] {
                group.lines.append(line)
                groupsByID[ingredientID] = group
            } else {
                // The joined columns are always present when the id is; the
                // fallbacks only keep this total if a caller hand-builds a row.
                groupsByID[ingredientID] = IngredientGroup(id: ingredientID,
                                                           name: row.ingredientName ?? row.name,
                                                           category: row.category ?? .other,
                                                           lines: [line],
                                                           isChecked: input.checkedIngredientIDs.contains(ingredientID),
                                                           sum: nil)
                groupOrder.append(ingredientID)
            }
        }

        var groups: [IngredientGroup] = []
        for id in groupOrder {
            guard var group = groupsByID[id] else { continue }
            group.sum = sum(of: group.lines)
            groups.append(group)
        }

        // Partition rather than sort so "created order" within each half is exactly
        // the input order the store returned (Swift's sort is not documented stable).
        let manualUnchecked = input.manualItems.filter { !$0.isChecked }
        let manualChecked = input.manualItems.filter { $0.isChecked }

        var sections: [GrocerySection] = []
        for category in IngredientCategory.storeOrder {
            let inCategory = groups.filter { $0.category == category }
            let ordered = sortedByName(inCategory.filter { !$0.isChecked })
                + sortedByName(inCategory.filter { $0.isChecked })
            var otherItems: [OtherItem] = []
            if category == .other {
                for textLine in textLines { otherItems.append(.text(textLine)) }
                for item in manualUnchecked { otherItems.append(.manual(item)) }
                for item in manualChecked { otherItems.append(.manual(item)) }
            }
            if ordered.isEmpty && otherItems.isEmpty { continue }
            sections.append(GrocerySection(category: category, groups: ordered, otherItems: otherItems))
        }

        let checkedGroups = groups.filter { $0.isChecked }.count
        let unchecked = (groups.count - checkedGroups) + textLines.count + manualUnchecked.count
        let checked = checkedGroups + manualChecked.count
        return GroceryList(sections: sections,
                           isEmpty: sections.isEmpty,
                           uncheckedCount: unchecked,
                           checkedCount: checked)
    }

    /// The §8 rule, exactly: a total only when there are at least two lines, every
    /// line has a finite quantity, and every `unitKey` is the same (nil == nil
    /// counts as the same: "2 onions" + "1 onion" → 3). Never converts, never sums
    /// across keys, never sums when any line lacks a number — a wrong sum is worse
    /// than no sum.
    static func sum(of lines: [GroceryLine]) -> QuantitySum? {
        guard lines.count >= 2, let first = lines.first else { return nil }
        let key = first.unitKey
        var total = 0.0
        for line in lines {
            guard let quantity = line.quantity, quantity.isFinite else { return nil }
            guard line.unitKey == key else { return nil }
            total += quantity
        }
        return QuantitySum(value: total, unitKey: key)
    }

    private static func sortedByName(_ groups: [IngredientGroup]) -> [IngredientGroup] {
        groups.sorted { a, b in
            switch a.name.caseInsensitiveCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.id < b.id
            }
        }
    }
}
