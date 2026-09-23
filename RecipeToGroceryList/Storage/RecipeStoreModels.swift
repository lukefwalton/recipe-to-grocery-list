import Foundation

// Value types at the RecipeStore boundary: the shapes its reads return and the
// errors its writes report. Each is a fact with database identity, deliberately
// distinct from the input drafts in `Model/RecipeDraft.swift` — a `DraftRow` is a
// proposal with no id, a `StoredRecipeIngredient` is a row that landed. Split out of
// RecipeStore.swift so that file stays focused on the connection and the write
// path, as `workout-logger` does in `Storage/WorkoutStoreModels.swift` (@5bffddfb80fc).

/// One canonical ingredient. `canonicalName` and `category` are `var` because the
/// user may rename (v1.1) and the seed refreshes the category; `slug` and `isCustom`
/// never change once written.
struct Ingredient: Equatable, Identifiable, Sendable {
    let id: Int64
    let slug: String
    var canonicalName: String
    var category: IngredientCategory
    let isCustom: Bool
}

/// A saved recipe as the Recipes screen shows it. `rawLines` is every line we were
/// given (§6 "never dropped"); `lineCount` is the number of `recipe_ingredients`
/// rows, which is what the row's "N ingredients" chrome means.
struct Recipe: Equatable, Identifiable, Sendable {
    let id: Int64
    var title: String
    let sourceKind: SourceKind
    let sourceRef: String?
    let servingsText: String?
    let rawLines: [String]
    var isSelected: Bool
    let lineCount: Int
    let createdAt: Date
    let updatedAt: Date
}

/// One `recipe_ingredients` row as stored. `ingredientID` is nil only for a row the
/// user kept as text (§6).
struct StoredRecipeIngredient: Equatable, Identifiable, Sendable {
    let id: Int64
    let recipeID: Int64
    let ingredientID: Int64?
    let rawLine: String
    let name: String
    let quantity: Double?
    let unitKey: String?
    let unitText: String?
    let note: String?
    let resolution: RowResolution
    let sortOrder: Int
}

/// An "also coffee" line the user typed on the list. Never merged with recipe
/// ingredients (§9) and checked individually — `checkedAt` present = checked.
struct ManualItem: Equatable, Identifiable, Sendable {
    let id: Int64
    var text: String
    var checkedAt: Date?
    let createdAt: Date

    var isChecked: Bool { checkedAt != nil }
}

/// One `recipe_ingredients` row of a *selected* recipe, joined with its recipe and
/// ingredient — the list's input (§9 "membership"). `ingredientID`,
/// `ingredientName` and `category` are all nil when the row was kept as text.
struct SelectedRow: Equatable, Sendable {
    let rowID: Int64
    let recipeID: Int64
    let recipeTitle: String
    let ingredientID: Int64?
    let ingredientName: String?
    let category: IngredientCategory?
    let name: String
    let quantity: Double?
    let unitKey: String?
    let unitText: String?
    let note: String?
    let sortOrder: Int
}

/// Everything the grocery list is a pure function of (§9): the selected recipes'
/// rows, the manual items, and which canonical ingredients are checked. Read in
/// one snapshot by `RecipeStore.groceryListInput()`, turned into a `GroceryList`
/// by `GroceryListBuilder` with no further database access.
struct GroceryListInput: Equatable, Sendable {
    var rows: [SelectedRow]
    var manualItems: [ManualItem]
    var checkedIngredientIDs: Set<Int64>

    static let empty = GroceryListInput(rows: [], manualItems: [], checkedIngredientIDs: [])
}

enum RecipeStoreError: Error, Equatable, CustomStringConvertible {
    /// A *Same as…* / *Use* alias already belongs to a different canonical (the
    /// alias table's PRIMARY KEY, §7.5). The whole save rolls back; the user picks
    /// explicitly. `alias` is the normalized term that collided, `ownerName` the
    /// current owner's canonical name.
    case aliasOwnedElsewhere(alias: String, ownerName: String)
    /// A draft or a check-off referenced an ingredient id that does not exist.
    case unknownIngredient(Int64)
    /// A selection toggle or rename targeted a recipe id that does not exist.
    case unknownRecipe(Int64)
    /// A rename to a blank title.
    case emptyName
    /// A manual item with no text after trimming.
    case blankManualItem

    var description: String {
        switch self {
        case .aliasOwnedElsewhere(let alias, let ownerName):
            return "\"\(alias)\" already means \(ownerName)"
        case .unknownIngredient(let id):
            return "No ingredient with id \(id)."
        case .unknownRecipe(let id):
            return "No recipe with id \(id)."
        case .emptyName:
            return "A recipe needs a title."
        case .blankManualItem:
            return "Type something to add to the list."
        }
    }
}
