import Foundation

/// The closed store-category vocabulary (spec §6). The raw values are exactly the
/// strings the schema's `CHECK (category IN (…))` accepts, so Swift and SQLite can
/// never disagree about what a category is.
///
/// Two orders exist on purpose: `allCases` is the declaration order (matches the
/// schema literal), `storeOrder` is the aisle order the grocery list renders in
/// (§9 — produce, bakery, dairy, meat, seafood, frozen, pantry, other). Grouping
/// by category is a closed decision (§13).
enum IngredientCategory: String, Codable, CaseIterable, Sendable {
    case produce, dairy, meat, seafood, bakery, pantry, frozen, other

    /// The order sections appear on the list, roughly the walk through a store.
    static let storeOrder: [IngredientCategory] = [
        .produce, .bakery, .dairy, .meat, .seafood, .frozen, .pantry, .other
    ]

    /// Position in `storeOrder`; lower sorts first.
    var storeRank: Int {
        Self.storeOrder.firstIndex(of: self) ?? Self.storeOrder.count
    }

    var displayName: String {
        switch self {
        case .produce: return "Produce"
        case .dairy: return "Dairy"
        case .meat: return "Meat"
        case .seafood: return "Seafood"
        case .bakery: return "Bakery"
        case .pantry: return "Pantry"
        case .frozen: return "Frozen"
        case .other: return "Other"
        }
    }

    /// SF Symbol for section headers and the category picker.
    var symbol: String {
        switch self {
        case .produce: return "leaf"
        case .dairy: return "cup.and.saucer"
        case .meat: return "fork.knife"
        case .seafood: return "fish"
        case .bakery: return "birthday.cake"
        case .pantry: return "cabinet"
        case .frozen: return "snowflake"
        case .other: return "basket"
        }
    }
}
