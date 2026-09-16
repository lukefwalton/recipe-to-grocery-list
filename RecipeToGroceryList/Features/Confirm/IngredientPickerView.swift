import SwiftUI
import LFWDesignSystem

/// What the user picked in `IngredientPickerView`: an existing canonical, one of
/// this session's new ingredients, or "create a new one in this category".
enum IngredientPick: Equatable {
    case existing(Int64)
    case pending(UUID)
    case create(IngredientCategory)
}

/// The *Same as…* / change-ingredient sheet (spec §7.5): the whole registry,
/// searchable, grouped in store order, with the row's close matches first and the
/// ingredients created earlier in this recipe above the registry. Callback-based —
/// it proposes nothing on its own and dismisses once the caller has accepted the
/// pick. The caller's `onPick` may throw an `AliasRefusal`; the sheet then stays
/// open and says why, so the user can pick something else without reopening it.
///
/// Shape copied from `MergeTargetPicker` in
/// `WorkoutChatLog/Features/ExerciseLibraryView.swift` at `workout-logger@5bffddfb80fc`
/// (a `NavigationStack` + searchable `List` of candidates with a Cancel item and a
/// callback), themed like the word app's lists.
struct IngredientPickerView: View {
    let title: String
    /// The row's name as written — the "Create “name”" row and the category step.
    let name: String
    let index: IngredientIndex
    let pending: [PendingIngredient]
    let closeMatches: [IngredientSuggestion]
    let theme: LFWThemeConfig
    let onPick: (IngredientPick) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var creating = false
    @State private var category: IngredientCategory = .other
    @State private var refusal: String?

    private var palette: LFWPaletteColors { theme.colors }

    var body: some View {
        NavigationStack {
            ThemedScreen(theme: theme) {
                if creating {
                    CategoryChooser(name: name, selection: $category, theme: theme) {
                        pick(.create(category))
                    }
                } else {
                    list
                }
            }
            .navigationTitle(creating ? "New ingredient" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if creating {
                        Button("Back") { creating = false }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .alert("Already taken", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(refusal ?? "")
            }
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            if !matchingCloseMatches.isEmpty {
                Section {
                    ForEach(matchingCloseMatches) { suggestion in
                        pickRow(title: suggestion.canonicalName, subtitle: Self.viaLabel(suggestion.via)) {
                            pick(.existing(suggestion.ingredientID))
                        }
                    }
                } header: {
                    header("Close matches")
                }
            }

            if !matchingPending.isEmpty {
                Section {
                    ForEach(matchingPending) { item in
                        pickRow(title: item.name, subtitle: "New · \(item.category.displayName)") {
                            pick(.pending(item.id))
                        }
                    }
                } header: {
                    header("New in this recipe")
                }
            }

            Section {
                Button {
                    creating = true
                } label: {
                    Label("Create “\(name)”", systemImage: "plus.circle")
                        .font(Theme.bodyFont(size: 16))
                        .foregroundStyle(palette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        pickRow(title: entry.canonicalName, subtitle: nil) {
                            pick(.existing(entry.id))
                        }
                    }
                } header: {
                    header(group.category.displayName)
                }
            }

            if groups.isEmpty && !query.isEmpty {
                Text("No ingredient matches “\(query)”.")
                    .font(Theme.bodyFont(size: 14))
                    .foregroundStyle(palette.secondaryText)
                    .listRowBackground(Color.clear)
            }
        }
        .modifier(ThemedListChrome(palette: palette))
        .searchable(text: $query, prompt: "Search ingredients")
    }

    private func pickRow(title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.bodyFont(size: 16))
                    .foregroundStyle(palette.primaryText)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(Theme.bodyFont(size: 12))
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(Theme.bodyFont(size: 12))
            .foregroundStyle(palette.secondaryText)
            .textCase(nil)
    }

    // MARK: - Filtering (the one normalization, §7.1)

    /// Every candidate is matched on `IngredientNormalizer.normalize`, both sides, so
    /// "Tomatoes" finds "tomato" and "jalapeño" finds "jalapeno". Aliases are stored
    /// normalized already (`IngredientIndexEntry.aliases`), so they are compared as-is.
    private var normalizedQuery: String { IngredientNormalizer.normalize(query) }

    private func matches(canonical: String, aliases: [String] = []) -> Bool {
        let key = normalizedQuery
        if key.isEmpty { return true }
        if IngredientNormalizer.normalize(canonical).contains(key) { return true }
        return aliases.contains { $0.contains(key) }
    }

    private var matchingCloseMatches: [IngredientSuggestion] {
        closeMatches.filter { matches(canonical: $0.canonicalName) }
    }

    private var matchingPending: [PendingIngredient] {
        pending.filter { matches(canonical: $0.name) }
    }

    private struct PickerGroup: Identifiable {
        let category: IngredientCategory
        let entries: [IngredientIndexEntry]
        var id: IngredientCategory { category }
    }

    /// Store order (§9), canonical names sorted case-insensitively inside each aisle,
    /// empty aisles omitted.
    private var groups: [PickerGroup] {
        let entries = index.entries.filter { matches(canonical: $0.canonicalName, aliases: $0.aliases) }
        return IngredientCategory.storeOrder.compactMap { category -> PickerGroup? in
            let members = entries
                .filter { $0.category == category }
                .sorted { $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending }
            return members.isEmpty ? nil : PickerGroup(category: category, entries: members)
        }
    }

    private static func viaLabel(_ via: RowResolution) -> String {
        switch via {
        case .llm: return "Suggested by on-device AI"
        case .fuzzy: return "Close spelling"
        case .embedding: return "Similar meaning"
        case .exact, .alias, .loose, .user, .none: return "Close match"
        }
    }

    // MARK: - Picking

    private func pick(_ choice: IngredientPick) {
        do {
            try onPick(choice)
            LFWHaptics.selection()
            dismiss()
        } catch let error as AliasRefusal {
            LFWHaptics.warning()
            refusal = error.message
        } catch {
            LFWHaptics.warning()
            refusal = "Couldn't use that ingredient. Try another."
        }
    }
}

// MARK: - Category

/// The category step of creating an ingredient: the eight aisles in store order,
/// `.other` preselected (the seed's default), one Create pill at the bottom. Shared by
/// the picker's "Create" row and the row-level **Create** button (`CategoryPickerSheet`).
struct CategoryChooser: View {
    let name: String
    @Binding var selection: IngredientCategory
    let theme: LFWThemeConfig
    let onCreate: () -> Void

    private var palette: LFWPaletteColors { theme.colors }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(IngredientCategory.storeOrder, id: \.self) { category in
                        Button {
                            selection = category
                            LFWHaptics.selection()
                        } label: {
                            HStack {
                                Label(category.displayName, systemImage: category.symbol)
                                    .font(Theme.bodyFont(size: 16))
                                    .foregroundStyle(palette.primaryText)
                                Spacer()
                                if category == selection {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Where “\(name)” sits in the store")
                        .font(Theme.bodyFont(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .textCase(nil)
                }
            }
            .modifier(ThemedListChrome(palette: palette))

            Button(action: onCreate) {
                Text("Create “\(name)” in \(selection.displayName)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .buttonStyle(LFWCTAButtonStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

/// The **Create** button's sheet on a *New* row: category only — the name is the
/// row's name as written, and `ConfirmModel.createIngredient` dedupes it.
struct CategoryPickerSheet: View {
    let name: String
    let theme: LFWThemeConfig
    let onCreate: (IngredientCategory) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: IngredientCategory = .other

    var body: some View {
        NavigationStack {
            ThemedScreen(theme: theme) {
                CategoryChooser(name: name, selection: $selection, theme: theme) {
                    onCreate(selection)
                    dismiss()
                }
            }
            .navigationTitle("New ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
