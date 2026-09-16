import Foundation

/// State behind the List tab (spec §8 display, §9 behaviour). The list is a PURE
/// FUNCTION of the store — `RecipeStore.groceryListInput()` read in one snapshot,
/// turned into sections by `GroceryListBuilder` — so this model holds no list state
/// of its own: every write goes through a typed `RecipeStore` API and is followed by
/// a rebuild, never by a local edit of `list`. That is why a checked heading sinks to
/// the bottom of its category "for free": the builder orders it, the view animates
/// the value change. Shape follows `WorkoutChatLog/Features/HistoryModel.swift` at
/// `workout-logger@5bffddfb80fc` (a `@MainActor ObservableObject` over the store,
/// reads through the store's typed API, every mutation through a dedicated
/// `@MainActor` store method — no SQL here), minus the async load: the list is a
/// few hundred rows at most, so it rebuilds synchronously on the main actor.
///
/// `@MainActor` because it drives the store's mutating APIs, which carry the
/// single-connection write invariant.
@MainActor
final class ListModel: ObservableObject {
    /// The current list. Starts as the empty build so the view never sees an
    /// uninitialised value before the first `reload()`.
    @Published private(set) var list: GroceryList = GroceryListBuilder.build(.empty)
    /// Set when the snapshot read fails; the view shows it instead of an empty
    /// state that would lie about there being nothing to buy.
    @Published private(set) var loadError: String?

    private let store: RecipeStore
    /// Called after every successful write — the view passes `{ appModel.didWrite() }`
    /// so the other screens (Recipes, Settings' counts) reload off `changeToken`.
    /// Main-actor typed so the model can call it synchronously.
    private let onWrite: @MainActor () -> Void

    init(store: RecipeStore, onWrite: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.onWrite = onWrite
    }

    // MARK: - Derived

    /// No selected recipes contribute a row AND there are no manual items — the
    /// `LFWEmptyState` deep link to Recipes (§4.1).
    var isEmpty: Bool { list.isEmpty }

    /// Any checked heading or checked manual item.
    var hasChecked: Bool { list.checkedCount > 0 }

    // MARK: - Read

    /// Rebuild from the store. A failed read keeps the previous `list` on screen and
    /// surfaces the error rather than flashing an empty list.
    func reload() {
        do {
            let input = try store.groceryListInput()
            list = GroceryListBuilder.build(input)
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Writes (§9)

    /// Check or uncheck an ingredient heading — across every recipe contributing
    /// to it, since `check_state` is keyed by the ingredient, not the line. The
    /// store deliberately runs no GC here (checking never changes membership).
    func toggle(group: IngredientGroup) throws {
        try store.setChecked(ingredientID: group.id, !group.isChecked)
        didWrite()
    }

    /// Manual items are checked individually and never merged with recipe lines.
    func toggleManual(_ item: ManualItem) throws {
        try store.setManualItemChecked(item.id, !item.isChecked)
        didWrite()
    }

    /// "Also coffee." Blank text is a no-op rather than an error: pressing return on
    /// an empty Add field should do nothing, not show an alert. The store trims and
    /// would refuse a blank itself (`RecipeStoreError.blankManualItem`); the guard
    /// here is what turns that refusal into silence.
    func addManual(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try store.addManualItem(trimmed)
        didWrite()
    }

    func deleteManual(_ item: ManualItem) throws {
        try store.deleteManualItem(item.id)
        didWrite()
    }

    /// Clear checked + Deselect all recipes, one store transaction (§9 "one button,
    /// one confirmation"). The view confirms before calling this. Unchecked manual
    /// items survive on purpose — they are still things to buy.
    func doneShopping() throws {
        try store.doneShopping()
        didWrite()
    }

    /// Rebuild first so the caller sees the new list synchronously (a toggle animates
    /// in the same frame), then signal the app. The app's `changeToken` bump will
    /// trigger one more `reload()` from the view; the second read returns an equal
    /// value, so nothing re-animates and the cost is one small snapshot read.
    private func didWrite() {
        reload()
        onWrite()
    }
}
