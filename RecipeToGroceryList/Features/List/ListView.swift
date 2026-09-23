import SwiftUI
import LFWDesignSystem

/// The List tab (spec §4.1, §8, §9): one merged list from the recipes marked
/// "cooking this", grouped by category in store order, one heading per canonical
/// ingredient with its constituent lines underneath, checkable by heading; manual
/// items under Other; a slim "Done shopping" at the bottom; gear → Settings.
///
/// The screen owns a `@StateObject` model that needs the store at init, and the
/// store lives on the environment object, which a `View.init` cannot read. So this
/// argument-less tab entry (what `RootTabView` constructs) reads it here and hands it
/// down — the workout app's `HistoryView.init(store:)` shape (@5bffddfb80fc) behind
/// the word app's environment-object entry (`Features/Practice/PracticeView.swift`
/// @e829bcc9c0dc). `StateObject`'s initial-value closure runs once per view
/// identity, so re-evaluating this body never rebuilds the model.
struct ListView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        // Capture the object, not `self`, so the write hook never reads a property
        // wrapper outside of a body evaluation. There is one AppModel per app, so the
        // closure the model keeps from its first construction stays correct.
        let model = appModel
        ListScreen(store: model.store, onWrite: { model.didWrite() })
    }
}

/// The actual screen. Presentation only: every write is a `ListModel` call (which is
/// a typed `RecipeStore` call followed by `appModel.didWrite()`), every read is the
/// model's `list` value. Copied in shape from `PracticeView` @e829bcc9c0dc (List
/// inside NavigationStack inside `ThemedScreen`, `ThemedListChrome`, `LFWEmptyState`)
/// with the confirm-then-write helpers of this app's `SettingsView`.
private struct ListScreen: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: ListModel

    @State private var newItemText = ""
    @State private var showingSettings = false
    @State private var confirmingDoneShopping = false
    @State private var actionError: String?

    init(store: RecipeStore, onWrite: @escaping @MainActor () -> Void) {
        _model = StateObject(wrappedValue: ListModel(store: store, onWrite: onWrite))
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
                        content
                    }
                }
                .navigationTitle("List")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .tint(palette.accent)
                        .accessibilityLabel("Settings")
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            // Sheets inherit the environment, but being explicit costs nothing and
            // the Settings screen cannot render without the model.
            SettingsView().environmentObject(appModel)
        }
        .onAppear { model.reload() }
        // The list is a pure function of the store (§9): any write anywhere — a
        // save on Confirm, a toggle on Recipes, Clear checked in Settings — bumps
        // the token, and one rebuild is the whole refresh story.
        .onChange(of: appModel.changeToken) { _, _ in model.reload() }
        .alert("Couldn't update the list", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: - States

    /// Nothing selected and nothing typed: deep-link to Recipes (§4.1 "no screen is
    /// ever blank"). The title face is the component's own; the design system is
    /// consumed as-is.
    private var empty: some View {
        LFWEmptyState(symbol: "checklist",
                      title: "Nothing to shop for yet",
                      message: "Pick the recipes you're cooking and they merge into one list.",
                      accent: palette.accent,
                      prominent: true) {
            Button("Choose recipes") {
                appModel.selectedTab = .recipes
            }
            .buttonStyle(.themedCTA(palette: palette))
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A failed snapshot read. Shown instead of the empty state, which would claim
    /// there is nothing to buy; the status tone is the on-palette `warning`.
    private func loadFailed(_ message: String) -> some View {
        LFWEmptyState(symbol: "exclamationmark.triangle",
                      title: "Couldn't load the list",
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

    private var content: some View {
        VStack(spacing: 0) {
            List {
                ForEach(model.list.sections) { section in
                    Section {
                        ForEach(section.groups) { group in
                            groupRow(group)
                        }
                        // Only ever non-empty for Other: kept-as-text rows, then
                        // manual items (unchecked before checked — the builder's order).
                        ForEach(section.otherItems) { item in
                            otherRow(item)
                        }
                    } header: {
                        sectionHeader(section.category)
                    }
                }
                Section {
                    addItemRow
                }
            }
            .modifier(ThemedListChrome(palette: palette))
            .scrollDismissesKeyboard(.interactively)
            // `GroceryList` is Equatable, so one value-driven animation covers every
            // change; the only visible motion is a checked heading settling to the
            // bottom of its category (§4.2 "nothing else animates"). Rows keep
            // stable ids (ingredient id / row id / manual id), so a move is a move.
            .animation(.default, value: model.list)

            footer
        }
    }

    // MARK: - Rows

    /// Category header in the chrome face: quiet, uppercase, secondary.
    private func sectionHeader(_ category: IngredientCategory) -> some View {
        Text(category.displayName)
            .font(Theme.bodyFont(size: 12))
            .kerning(1.2)
            .textCase(.uppercase)
            .foregroundStyle(palette.secondaryText)
    }

    /// The checkable unit (§9): the heading is the ingredient in the display face —
    /// the one display moment on this screen — and the lines under it are chrome.
    /// The whole row is the button; individual lines are not checkable.
    private func groupRow(_ group: IngredientGroup) -> some View {
        Button {
            toggle(group)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                checkCircle(group.isChecked)
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(Theme.displayFont(theme, size: 20))
                        .strikethrough(group.isChecked, color: palette.secondaryText)
                        .foregroundStyle(group.isChecked ? palette.secondaryText : palette.primaryText)
                    ForEach(group.lines) { line in
                        Text(lineText(line))
                            .font(Theme.bodyFont(size: 14))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                Spacer(minLength: 8)
                // The honest total (§8): present only when every line has a quantity
                // and they share a unit key. Numerals are always the chrome face.
                if let sum = group.sum {
                    Text(sum.text)
                        .font(Theme.bodyFont(size: 15))
                        .foregroundStyle(group.isChecked ? palette.secondaryText : palette.primaryText)
                        .accessibilityLabel("Total \(sum.text)")
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(group.isChecked ? "Checked" : "Not checked")
        .accessibilityHint(group.isChecked ? "Double-tap to uncheck" : "Double-tap to check")
    }

    /// One recipe line under a heading: "2 cups — Lentil soup", or "— Lentil soup"
    /// when the recipe gave no amount (§8 "no quantity given").
    private func lineText(_ line: GroceryLine) -> String {
        let amount = line.amountText
        return amount.isEmpty ? "— \(line.recipeTitle)" : "\(amount) — \(line.recipeTitle)"
    }

    @ViewBuilder
    private func otherRow(_ item: OtherItem) -> some View {
        switch item {
        case .text(let line):
            textRow(line)
        case .manual(let manualItem):
            manualRow(manualItem)
        }
    }

    /// A row the user kept as text: there is no ingredient to key a check on, so it
    /// is not checkable (§9) — shown quiet, with its recipe, so it is still bought.
    private func textRow(_ line: GroceryLine) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.quote")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(palette.secondaryText.opacity(0.7))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.name)
                    .font(Theme.bodyFont(size: 16))
                    .foregroundStyle(palette.secondaryText)
                Text(lineText(line))
                    .font(Theme.bodyFont(size: 13))
                    .foregroundStyle(palette.secondaryText.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(line.name), \(lineText(line)), kept as text")
    }

    /// "Also coffee": checked individually, swipe to delete. Never merged with a
    /// recipe ingredient (§9), so it has no heading and no sum.
    private func manualRow(_ item: ManualItem) -> some View {
        Button {
            toggleManual(item)
        } label: {
            HStack(spacing: 12) {
                checkCircle(item.isChecked)
                Text(item.text)
                    .font(Theme.bodyFont(size: 17))
                    .strikethrough(item.isChecked, color: palette.secondaryText)
                    .foregroundStyle(item.isChecked ? palette.secondaryText : palette.primaryText)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(item.isChecked ? "Checked" : "Not checked")
        .accessibilityHint(item.isChecked ? "Double-tap to uncheck" : "Double-tap to check")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                deleteManual(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            // The destructive role would paint system red; status stays on-palette.
            .tint(Theme.danger)
        }
    }

    /// Check-off affordance: `success` when checked (§4.2), quiet when not.
    private func checkCircle(_ checked: Bool) -> some View {
        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(checked ? Theme.success : palette.secondaryText)
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    /// The slim "Add item" row at the end of the list. Return submits; a blank
    /// return is a no-op (the model ignores blanks).
    private var addItemRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 22)
                .accessibilityHidden(true)
            TextField("Add item", text: $newItemText)
                .font(Theme.bodyFont(size: 16))
                .foregroundStyle(palette.primaryText)
                .tint(palette.accent)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .onSubmit { addManual() }
                .accessibilityLabel("Add item")
            if !newItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    addManual()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add")
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Footer (§9 "Done shopping" — one button, one confirmation)

    private var footer: some View {
        VStack(spacing: 8) {
            Text(summaryText)
                .font(Theme.bodyFont(size: 13))
                .foregroundStyle(palette.secondaryText)
            Button("Done shopping") {
                confirmingDoneShopping = true
            }
            .buttonStyle(.themedCTA(palette: palette, filled: false))
            .confirmationDialog("Done shopping?",
                                isPresented: $confirmingDoneShopping,
                                titleVisibility: .visible) {
                Button("Done shopping", role: .destructive) { doneShopping() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears every check and deselects all recipes.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// "3 to buy · 2 checked" — the counts the builder already computes. Numerals
    /// in the chrome face like everything else here.
    private var summaryText: String {
        let left = model.list.uncheckedCount
        var text = "\(left) to buy"
        if model.hasChecked {
            text += " · \(model.list.checkedCount) checked"
        }
        return text
    }

    // MARK: - Writes

    // The store's writes are `@MainActor`; the helpers say so explicitly (as this
    // app's `SettingsView` does) rather than relying on the SDK's `View` isolation,
    // which differs between Xcode 15 and 16.

    @MainActor
    private func toggle(_ group: IngredientGroup) {
        if perform({ try model.toggle(group: group) }) {
            LFWHaptics.selection()
        }
    }

    @MainActor
    private func toggleManual(_ item: ManualItem) {
        if perform({ try model.toggleManual(item) }) {
            LFWHaptics.selection()
        }
    }

    @MainActor
    private func addManual() {
        let text = newItemText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if perform({ try model.addManual(text) }) {
            newItemText = ""
            LFWHaptics.impact()
        }
    }

    @MainActor
    private func deleteManual(_ item: ManualItem) {
        perform { try model.deleteManual(item) }
    }

    @MainActor
    private func doneShopping() {
        if perform({ try model.doneShopping() }) {
            LFWHaptics.success()
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

    private var errorPresented: Binding<Bool> {
        Binding(get: { actionError != nil },
                set: { if !$0 { actionError = nil } })
    }
}
