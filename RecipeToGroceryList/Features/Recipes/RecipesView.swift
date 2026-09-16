import SwiftUI
import LFWDesignSystem

/// The Recipes tab (spec §4.1): every saved recipe as a card — title in the display
/// face, source kind + line count in chrome type, a "cooking this" toggle on the row.
/// Swipe to delete (confirmed), context menu to rename, tap for the stored rows.
///
/// Same two-layer shape as `ListView`: this argument-less entry (what `RootTabView`
/// constructs) reads the store off the environment object and hands it to the screen
/// that owns the `@StateObject` — the workout app's `HistoryView.init(store:)`
/// (@5bffddfb80fc) behind the word app's environment-object entry
/// (`Features/Practice/PracticeView.swift` @e829bcc9c0dc).
struct RecipesView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        // Capture the object, not `self`, so the write hook never reads a property
        // wrapper outside of a body evaluation.
        let model = appModel
        RecipesScreen(store: model.store, onWrite: { model.didWrite() })
    }
}

/// Presentation only: every write is a `RecipesModel` call (a typed `RecipeStore`
/// call followed by `appModel.didWrite()`). List chrome from `PracticeView`
/// @e829bcc9c0dc, swipe / context actions from the workout `HistoryView`
/// @5bffddfb80fc, confirm-then-write helpers from this app's `SettingsView`.
private struct RecipesScreen: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: RecipesModel

    /// The pushed detail, by id. `Recipe` is not `Hashable`, and a value-based
    /// destination needs one, so the id is the navigation value and the detail
    /// re-reads the recipe from the store (which also keeps it live across a rename).
    @State private var detailRecipeID: Int64?
    @State private var deleting: Recipe?
    @State private var renaming: Recipe?
    @State private var renameText = ""
    @State private var actionError: String?

    init(store: RecipeStore, onWrite: @escaping @MainActor () -> Void) {
        _model = StateObject(wrappedValue: RecipesModel(store: store, onWrite: onWrite))
    }

    private var theme: LFWThemeConfig { appModel.theme }
    private var palette: LFWPaletteColors { appModel.theme.colors }

    var body: some View {
        ThemedScreen(theme: theme) {
            NavigationStack {
                Group {
                    if let error = model.loadError {
                        loadFailed(error)
                    } else if model.isEmpty {
                        empty
                    } else {
                        list
                    }
                }
                .navigationTitle("Recipes")
                .navigationDestination(item: $detailRecipeID) { id in
                    RecipeDetailView(recipeID: id)
                }
            }
        }
        .onAppear { model.reload() }
        .onChange(of: appModel.changeToken) { _, _ in model.reload() }
        // Destructive, so confirmed (§4.1). `presenting:` hands the recipe into the
        // action so the delete never depends on `deleting` still being set when the
        // button's action runs.
        .confirmationDialog(deleteTitle,
                            isPresented: deletingPresented,
                            titleVisibility: .visible,
                            presenting: deleting) { recipe in
            Button("Delete", role: .destructive) { delete(recipe) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its lines leave the list.")
        }
        .alert("Rename recipe", isPresented: renamingPresented, presenting: renaming) { recipe in
            TextField("Title", text: $renameText)
            Button("Save") { rename(recipe) }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Only the title changes; its ingredients stay as they are.")
        }
        .alert("Couldn't update recipes", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - States

    /// Nothing saved: deep-link to Add (§4.1 "no screen is ever blank").
    private var empty: some View {
        LFWEmptyState(symbol: "book.closed",
                      title: "No recipes yet",
                      message: "Add one from a link, pasted text, or a photo.",
                      accent: palette.accent,
                      prominent: true) {
            Button("Add a recipe") {
                appModel.selectedTab = .add
            }
            .buttonStyle(.themedCTA(palette: palette))
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFailed(_ message: String) -> some View {
        LFWEmptyState(symbol: "exclamationmark.triangle",
                      title: "Couldn't load your recipes",
                      message: message,
                      accent: Theme.warning) {
            Button("Try again") {
                model.reload()
            }
            .buttonStyle(.themedCTA(palette: palette, filled: false))
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Card rows on the plain themed list. The row background is cleared and the
    /// separator hidden per row so the `lfwCard` surface is the row's only surface,
    /// floating on the gradient like the word app's feature cards.
    private var list: some View {
        List {
            ForEach(model.recipes) { recipe in
                recipeRow(recipe)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleting = recipe
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        // The destructive role would paint system red; status stays on-palette.
                        .tint(Theme.danger)
                    }
                    .contextMenu {
                        Button {
                            beginRename(recipe)
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button {
                            detailRecipeID = recipe.id
                        } label: {
                            Label("Show ingredients", systemImage: "list.bullet")
                        }
                        Button(role: .destructive) {
                            deleting = recipe
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .modifier(ThemedListChrome(palette: palette))
    }

    // MARK: - Row

    /// Title in the display face (the one display moment on this screen), the
    /// chrome line under it, the toggle on the right. The text is the tap target
    /// for the detail; the toggle is its own control, so a flip never navigates.
    private func recipeRow(_ recipe: Recipe) -> some View {
        HStack(spacing: 12) {
            Button {
                detailRecipeID = recipe.id
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recipe.title)
                        .font(Theme.displayFont(theme, size: 20))
                        .foregroundStyle(palette.primaryText)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(subtitle(recipe))
                        .font(Theme.bodyFont(size: 13))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(recipe.title). \(subtitle(recipe))")
            .accessibilityHint("Shows the recipe's ingredients")

            Toggle("Cooking this", isOn: selectionBinding(recipe))
                .labelsHidden()
                .tint(palette.accent)
                .accessibilityLabel("Cooking this")
        }
        .lfwCard(fill: palette.surface, padding: 12)
    }

    /// "Link · 12 ingredients · Serves 4" — only the parts present. Numerals in the
    /// chrome face (§4.2).
    private func subtitle(_ recipe: Recipe) -> String {
        var parts = [
            recipe.sourceKind.displayName,
            "\(recipe.lineCount) \(recipe.lineCount == 1 ? "ingredient" : "ingredients")",
        ]
        if let servings = recipe.servingsText, !servings.isEmpty {
            parts.append(servings)
        }
        return parts.joined(separator: " · ")
    }

    /// Reads the store's current value for the row (the model reloads synchronously
    /// after a write), so the switch never snaps back to a stale render.
    private func selectionBinding(_ recipe: Recipe) -> Binding<Bool> {
        Binding(
            get: { model.recipe(id: recipe.id)?.isSelected ?? recipe.isSelected },
            set: { on in setSelected(recipe, on) }
        )
    }

    private var deleteTitle: String {
        "Delete “\(deleting?.title ?? "")”?"
    }

    // MARK: - Writes

    // The store's writes are `@MainActor`; the helpers say so explicitly (as this
    // app's `SettingsView` does) rather than relying on the SDK's `View` isolation,
    // which differs between Xcode 15 and 16.

    @MainActor
    private func setSelected(_ recipe: Recipe, _ on: Bool) {
        let current = model.recipe(id: recipe.id)?.isSelected ?? recipe.isSelected
        guard on != current else { return }
        if perform({ try model.setSelected(recipe, on) }) {
            LFWHaptics.selection()
        }
    }

    @MainActor
    private func delete(_ recipe: Recipe) {
        if perform({ try model.delete(recipe) }) {
            LFWHaptics.impact()
        }
    }

    @MainActor
    private func beginRename(_ recipe: Recipe) {
        renameText = recipe.title
        renaming = recipe
    }

    @MainActor
    private func rename(_ recipe: Recipe) {
        // The store trims and refuses a blank (`RecipeStoreError.emptyName`); the
        // Save button is also disabled for one, so this is the belt to that brace.
        if perform({ try model.rename(recipe, title: renameText) }) {
            LFWHaptics.impact()
        }
    }

    /// Runs one write; a failure becomes the alert plus the failure haptic and
    /// returns false so the caller skips its success haptic.
    @MainActor
    @discardableResult
    private func perform(_ write: () throws -> Void) -> Bool {
        do {
            try write()
            return true
        } catch {
            actionError = String(describing: error)
            LFWHaptics.failure()
            return false
        }
    }

    private var deletingPresented: Binding<Bool> {
        Binding(get: { deleting != nil },
                set: { if !$0 { deleting = nil } })
    }

    private var renamingPresented: Binding<Bool> {
        Binding(get: { renaming != nil },
                set: { if !$0 { renaming = nil } })
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { actionError != nil },
                set: { if !$0 { actionError = nil } })
    }
}

// MARK: - Detail

/// One saved recipe as stored: where it came from, its servings text (raw, display
/// only — §2 non-goal), and its `recipe_ingredients` rows with what each was matched
/// to. Read-only; there is nothing to write here. Re-reads on `changeToken` so a
/// rename from the list shows through. Pushed inside the tab's `NavigationStack`,
/// so it sits on the same `ThemedScreen` gradient as the list.
private struct RecipeDetailView: View {
    let recipeID: Int64

    @EnvironmentObject private var appModel: AppModel
    @State private var recipe: Recipe?
    @State private var rows: [StoredRecipeIngredient] = []
    /// Canonical names for the matched rows, looked up once per load so a row never
    /// shows a bare id.
    @State private var canonicalNames: [Int64: String] = [:]
    @State private var loadError: String?

    private var theme: LFWThemeConfig { appModel.theme }
    private var palette: LFWPaletteColors { appModel.theme.colors }

    var body: some View {
        Group {
            if let error = loadError {
                loadFailed(error)
            } else if let recipe {
                content(recipe)
            } else {
                missing
            }
        }
        // The title is the display moment inside the content; the bar stays quiet.
        .navigationTitle("Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        .onChange(of: appModel.changeToken) { _, _ in reload() }
    }

    private func content(_ recipe: Recipe) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(recipe.title)
                        .font(Theme.displayFont(theme, size: 28))
                        .foregroundStyle(palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    sourceLine(recipe)
                        .font(Theme.bodyFont(size: 14))
                        .foregroundStyle(palette.secondaryText)
                    if let servings = recipe.servingsText, !servings.isEmpty {
                        Label(servings, systemImage: "person.2")
                            .font(Theme.bodyFont(size: 14))
                            .foregroundStyle(palette.secondaryText)
                    }
                    if recipe.isSelected {
                        Label("Cooking this", systemImage: "checkmark.circle.fill")
                            .font(Theme.bodyFont(size: 14))
                            .foregroundStyle(Theme.success)
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(rows) { row in
                    ingredientRow(row)
                }
            } header: {
                Text("\(rows.count) \(rows.count == 1 ? "ingredient" : "ingredients")")
                    .font(Theme.bodyFont(size: 12))
                    .kerning(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .modifier(ThemedListChrome(palette: palette))
    }

    /// Link → the stored URL as a tappable `Link`; Pasted / Photo → the kind.
    @ViewBuilder
    private func sourceLine(_ recipe: Recipe) -> some View {
        switch recipe.sourceKind {
        case .url:
            if let ref = recipe.sourceRef, let url = URL(string: ref) {
                Link(destination: url) {
                    Label(ref, systemImage: recipe.sourceKind.symbol)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .tint(palette.accent)
            } else {
                Label(recipe.sourceKind.displayName, systemImage: recipe.sourceKind.symbol)
            }
        case .text, .photo:
            Label(recipe.sourceKind.displayName, systemImage: recipe.sourceKind.symbol)
        }
    }

    /// "3 cloves garlic" over "matched to Garlic · minced", or "Kept as text" for a
    /// row with no ingredient (§6). The `resolution` column stays where it is —
    /// telemetry that never leaves the database.
    private func ingredientRow(_ row: StoredRecipeIngredient) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(primaryText(row))
                .font(Theme.bodyFont(size: 16))
                .foregroundStyle(palette.primaryText)
            Text(secondaryText(row))
                .font(Theme.bodyFont(size: 13))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func primaryText(_ row: StoredRecipeIngredient) -> String {
        let amount = QuantityFormat.string(quantity: row.quantity, unitKey: row.unitKey, unitText: row.unitText)
        return amount.isEmpty ? row.name : "\(amount) \(row.name)"
    }

    private func secondaryText(_ row: StoredRecipeIngredient) -> String {
        var parts: [String] = []
        if let id = row.ingredientID {
            parts.append("matched to \(canonicalNames[id] ?? "ingredient #\(id)")")
        } else {
            parts.append("Kept as text")
        }
        if let note = row.note, !note.isEmpty {
            parts.append(note)
        }
        return parts.joined(separator: " · ")
    }

    /// The id no longer resolves — the recipe was deleted while this was up.
    private var missing: some View {
        LFWEmptyState(symbol: "book.closed",
                      title: "Recipe not found",
                      message: "It may have been deleted.",
                      accent: palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadFailed(_ message: String) -> some View {
        LFWEmptyState(symbol: "exclamationmark.triangle",
                      title: "Couldn't load this recipe",
                      message: message,
                      accent: Theme.warning) {
            Button("Try again") {
                reload()
            }
            .buttonStyle(.themedCTA(palette: palette, filled: false))
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The recipe, its rows and the matched names in ONE store snapshot, so a save
    /// committing mid-read can't show rows that belong to a title that just changed.
    @MainActor
    private func reload() {
        let store = appModel.store
        let id = recipeID
        do {
            let loaded = try store.snapshot { () throws -> (Recipe?, [StoredRecipeIngredient], [Int64: String]) in
                let found = try store.recipe(id: id)
                let items = try store.recipeIngredients(recipeID: id)
                var names: [Int64: String] = [:]
                for ingredientID in Set(items.compactMap(\.ingredientID)) {
                    names[ingredientID] = try store.ingredient(id: ingredientID)?.canonicalName
                }
                return (found, items, names)
            }
            recipe = loaded.0
            rows = loaded.1
            canonicalNames = loaded.2
            loadError = nil
        } catch {
            loadError = String(describing: error)
        }
    }
}
