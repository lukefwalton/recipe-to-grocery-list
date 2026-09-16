import SwiftUI
import LFWDesignSystem

/// The Confirm screen (spec §7.5): the recipe title, a status line about how the
/// draft was made, then one row per raw line in source order with section headers
/// interleaved as greyed dividers, and one Save pill that stays disabled until every
/// row has been decided. Nothing is written until Save; Save goes through
/// `AppModel.saveRecipe` → `RecipeStore.save`, the one write path (§1).
///
/// Layout follows the word app's `PracticeView` (a `List` under `ThemedListChrome`
/// inside `ThemedScreen`, `WordOfTheDay/Features/Practice/PracticeView.swift` at
/// `a-new-word-every-day@e829bcc9c0dc`); the "one display moment" is the title
/// field in the theme's display face, everything below it is chrome type (§4.2).
struct ConfirmView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: ConfirmModel
    private let onSaved: (Int64) -> Void

    @State private var saveError: String?

    /// `index` is the registry snapshot the taps are checked against — the caller
    /// reads it once (`RecipeStore.ingredientIndex()`) so this view never touches the
    /// store for anything but the save.
    init(parsed: ParsedRecipe, index: IngredientIndex, onSaved: @escaping (Int64) -> Void) {
        _model = StateObject(wrappedValue: ConfirmModel(parsed: parsed, index: index))
        self.onSaved = onSaved
    }

    private var palette: LFWPaletteColors { appModel.theme.colors }

    var body: some View {
        ThemedScreen(theme: appModel.theme) {
            VStack(spacing: 0) {
                List {
                    titleSection
                    ForEach(lines) { line in
                        switch line {
                        case .header(_, let text):
                            headerDivider(text)
                        case .row(let row):
                            ConfirmRowView(model: model, row: row, theme: appModel.theme)
                        }
                    }
                }
                .modifier(ThemedListChrome(palette: palette))
                .scrollDismissesKeyboard(.interactively)

                saveBar
            }
        }
        .navigationTitle("Confirm")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Title + status

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Recipe title", text: $model.draft.title)
                .font(Theme.displayFont(appModel.theme))
                .foregroundStyle(palette.primaryText)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .accessibilityLabel("Recipe title")
            statusLine
        }
        .padding(.vertical, 8)
    }

    /// Source kind + line count, then the honest notes about the parse: the model's
    /// own warning (or "Parsed without on-device AI." when it declined), the §7.6
    /// copy when the device has no on-device AI at all, and "Parsed with on-device
    /// AI" when it did the refining — so the user knows how much to trust the rows.
    @ViewBuilder
    private var statusLine: some View {
        Text(sourceSummary)
            .font(Theme.bodyFont(size: 13))
            .foregroundStyle(palette.secondaryText)
        if model.usedOnDeviceAI {
            Label("Parsed with on-device AI", systemImage: "sparkles")
                .font(Theme.bodyFont(size: 13))
                .foregroundStyle(palette.secondaryText)
        }
        if let warning = model.warning {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(Theme.bodyFont(size: 13))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !appModel.onDeviceAIAvailable {
            Text(RecipeParserFactory.unavailableCopy)
                .font(Theme.bodyFont(size: 13))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceSummary: String {
        let count = model.draft.rows.count
        var pieces = [model.draft.source.kind.displayName, count == 1 ? "1 line" : "\(count) lines"]
        if let servings = model.draft.source.servingsText?.trimmingCharacters(in: .whitespacesAndNewlines), !servings.isEmpty {
            pieces.append(servings)   // display only, never parsed (§2)
        }
        return pieces.joined(separator: " · ")
    }

    // MARK: - Lines in source order (§5.2, §7.5)

    private enum ConfirmLine: Identifiable {
        case header(index: Int, text: String)
        case row(DraftRow)

        var id: String {
            switch self {
            case .header(let index, _): return "header-\(index)"
            case .row(let row): return row.id.uuidString
            }
        }
    }

    /// Walk `rawLines`: a header index renders as a divider, every other index is a
    /// row (`DraftRow.lineIndex` points back into `rawLines`), so the screen shows
    /// every line the user gave us in the order they gave it.
    private var lines: [ConfirmLine] {
        let headers = Set(model.draft.headerLineIndices)
        var rowsByLine: [Int: DraftRow] = [:]
        for row in model.draft.rows {
            rowsByLine[row.lineIndex] = row
        }
        return model.draft.rawLines.indices.compactMap { index -> ConfirmLine? in
            if headers.contains(index) {
                return .header(index: index, text: model.draft.rawLines[index])
            }
            if let row = rowsByLine[index] {
                return .row(row)
            }
            return nil
        }
    }

    /// A section header ("For the sauce:") — not an ingredient, not stored as a row,
    /// shown greyed so the user sees where it went.
    private func headerDivider(_ text: String) -> some View {
        Text(text)
            .font(Theme.bodyFont(size: 13))
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityLabel("Section: \(text)")
    }

    // MARK: - Save

    private var saveBar: some View {
        Button(action: save) {
            Text(saveLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(LFWCTAButtonStyle())
        .disabled(!model.canSave)
        .opacity(model.canSave ? 1 : 0.55)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Save is disabled until no row is *New* or *Suggested* (§7.5); the label says
    /// what is still in the way.
    private var saveLabel: String {
        let pending = model.rowsNeedingDecision
        if pending > 0 {
            return pending == 1 ? "Resolve 1 row to save" : "Resolve \(pending) rows to save"
        }
        if model.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Add a title to save"
        }
        if model.draft.keptRows.isEmpty {
            return "Keep at least one row to save"
        }
        return "Save"
    }

    /// `AppModel.saveRecipe` runs the store's validate → transaction → rows, bumps the
    /// reload token and fires the success haptic. A refused alias (the alias table's
    /// PRIMARY KEY, §7.5) rolls the whole save back and is shown by name with the
    /// warning haptic; anything else gets one stable sentence, never a raw error.
    private func save() {
        do {
            let recipeID = try appModel.saveRecipe(model.draft)
            onSaved(recipeID)
        } catch let error as RecipeStoreError {
            if case .aliasOwnedElsewhere = error {
                LFWHaptics.warning()
            } else {
                LFWHaptics.failure()
            }
            saveError = error.description
        } catch {
            LFWHaptics.failure()
            saveError = "The recipe couldn't be saved. Check the rows and try again."
        }
    }
}
