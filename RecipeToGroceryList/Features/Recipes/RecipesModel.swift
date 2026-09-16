import Foundation

/// State behind the Recipes tab (spec §4.1): the saved recipes newest first, the
/// "cooking this" toggle, delete and rename. Reads go through `RecipeStore.recipes()`;
/// every mutation goes through a dedicated `@MainActor` store API and is followed by
/// a reload, so `recipes` is never edited locally and can never disagree with the
/// database. The check-state GC that rides along with `setSelected` / `deleteRecipe`
/// (§9) happens inside the store's transaction, not here. Shape follows
/// `WorkoutChatLog/Features/HistoryModel.swift` at `workout-logger@5bffddfb80fc`,
/// minus the async load (a handful of rows).
///
/// `@MainActor` because it drives the store's mutating APIs, which carry the
/// single-connection write invariant.
@MainActor
final class RecipesModel: ObservableObject {
    /// Newest first (`created_at DESC, id DESC`), with each recipe's `lineCount`.
    @Published private(set) var recipes: [Recipe] = []
    /// Set when the read fails; the view shows it instead of "No recipes yet".
    @Published private(set) var loadError: String?

    private let store: RecipeStore
    /// Called after every successful write — the view passes `{ appModel.didWrite() }`
    /// so the List tab rebuilds off `changeToken`.
    private let onWrite: @MainActor () -> Void

    init(store: RecipeStore, onWrite: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.onWrite = onWrite
    }

    // MARK: - Derived

    /// Nothing saved — the `LFWEmptyState` deep link to Add (§4.1).
    var isEmpty: Bool { recipes.isEmpty }

    /// The current row for an id, so a toggle binding reads the value the store
    /// has rather than the one the row was rendered with.
    func recipe(id: Int64) -> Recipe? {
        recipes.first { $0.id == id }
    }

    // MARK: - Read

    func reload() {
        do {
            recipes = try store.recipes()
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }

    // MARK: - Writes

    /// "Cooking this" on/off. The store GCs orphaned check state in the same
    /// transaction — the only side effect of a toggle (§9).
    func setSelected(_ recipe: Recipe, _ on: Bool) throws {
        try store.setSelected(recipe.id, on)
        didWrite()
    }

    /// Rows cascade and the same GC as deselecting runs (§6, §9). The view confirms
    /// first: "Delete “title”? Its lines leave the list."
    func delete(_ recipe: Recipe) throws {
        try store.deleteRecipe(recipe.id)
        didWrite()
    }

    /// Title only. The store trims and throws `RecipeStoreError.emptyName` for a
    /// blank, which propagates untouched so the view can show the refusal; nothing
    /// is signalled on failure.
    func rename(_ recipe: Recipe, title: String) throws {
        try store.renameRecipe(recipe.id, title: title)
        didWrite()
    }

    private func didWrite() {
        reload()
        onWrite()
    }
}
