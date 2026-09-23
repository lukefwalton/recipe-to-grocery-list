import SwiftUI
import LFWDesignSystem

/// One raw line on the Confirm screen — the §7.5 state table, rendered:
///
/// | state       | shows                                              | actions                              |
/// |-------------|----------------------------------------------------|--------------------------------------|
/// | resolved    | canonical name, amount · note (· name as written)  | tap → change ingredient, Edit        |
/// | highlighted | name as written, amount, warning dot "matched to X"| leave it, or tap → change            |
/// | suggested   | bold name, amount, "Looks like X", **Use**         | Use writes an alias; tap → picker    |
/// | new         | bold name, amount, "New ingredient"                | Create / Same as… / Keep as text     |
/// | text        | name, amount, "Kept as text"                        | tap → picker                         |
/// | removed     | greyed, struck through                             | Restore                              |
///
/// Every row also has **Not an ingredient** and **Edit** on swipe and in the context
/// menu. The row never touches the draft directly: every tap is a `ConfirmModel`
/// call, and the model is the only thing that can change a row. Colors are palette
/// roles plus the three status tokens (`Theme.warning` dot, `Theme.danger` remove);
/// type is the chrome face throughout (§4.2 — numerals are always Inter), with the
/// design system's semibold weight axis (the `.uiTitle` role on the chrome face) for
/// the "bold name" the state table asks for, because `.fontWeight` cannot move a
/// variable font's `wght` axis (see `LFWVariableFont`).
///
/// The **Use** chip is the workout app's "Did you mean…" suggestion tap
/// (`WorkoutChatLog/Features/TodayView.swift` `applySuggestion` at
/// `workout-logger@5bffddfb80fc`); the swipe + context-menu pair and the error alert
/// bound to an optional follow `ExerciseLibraryView.swift` in the same repo. The pills
/// are the word app's `ThemedCTAButtonStyle` (ported into `App/Theme.swift`) rather
/// than `LFWCTAButtonStyle`'s outlined variant, which draws `paper` on `paper` on the
/// light palettes and is sized for a full-width onboarding CTA, not three-up in a row.
struct ConfirmRowView: View {
    @ObservedObject var model: ConfirmModel
    let row: DraftRow
    let theme: LFWThemeConfig

    @State private var sheet: RowSheet?
    @State private var refusal: AliasRefusal?

    /// Written out rather than left to the memberwise initializer. Swift makes the
    /// synthesized memberwise init **private** when any stored property is private,
    /// and `sheet`/`refusal` are (`@State` synthesizes a private `_sheet`), so
    /// `ConfirmRowView(model:row:theme:)` would not be callable from `ConfirmView`.
    /// The same reason `OCRCandidateRow` spells its init out in
    /// `workout-logger@5bffddfb80fc`. This also states the view's real API: three
    /// inputs, and the local state is nobody else's business.
    init(model: ConfirmModel, row: DraftRow, theme: LFWThemeConfig) {
        _model = ObservedObject(wrappedValue: model)
        self.row = row
        self.theme = theme
    }

    private var palette: LFWPaletteColors { theme.colors }

    private enum RowSheet: Identifiable {
        /// The ingredient picker. `addAlias` is true when the tap decides an undecided
        /// row (*Same as…*), false when it merely changes a decided one.
        case picker(addAlias: Bool)
        case category
        case edit

        var id: String {
            switch self {
            case .picker(let addAlias): return addAlias ? "same-as" : "change"
            case .category: return "category"
            case .edit: return "edit"
            }
        }
    }

    var body: some View {
        content
            .padding(.vertical, 6)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if row.isRemoved {
                    Button(action: restore) {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .tint(Theme.success)
                } else {
                    Button(action: removeRow) {
                        Label("Not an ingredient", systemImage: "xmark.circle")
                    }
                    .tint(Theme.danger)
                }
                Button {
                    sheet = .edit
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(palette.accent)
            }
            .contextMenu {
                if !row.isRemoved {
                    Button {
                        sheet = .picker(addAlias: !isDecided)
                    } label: {
                        Label(isDecided ? "Change ingredient" : "Same as…", systemImage: "arrow.left.arrow.right")
                    }
                    Button {
                        sheet = .edit
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: removeRow) {
                        Label("Not an ingredient", systemImage: "xmark.circle")
                    }
                } else {
                    Button(action: restore) {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .picker(let addAlias):
                    IngredientPickerView(title: addAlias ? "Same as…" : "Change ingredient",
                                         name: row.name,
                                         index: model.index,
                                         pending: model.draft.newIngredients,
                                         closeMatches: model.alternatives(for: row.id),
                                         theme: theme) { pick in
                        try apply(pick, addAlias: addAlias)
                    }
                case .category:
                    CategoryPickerSheet(name: row.name, theme: theme) { category in
                        model.createIngredient(row.id, category: category)
                        LFWHaptics.selection()
                    }
                case .edit:
                    RowEditSheet(model: model, row: row, theme: theme)
                }
            }
            .alert("Already taken", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(refusal?.message ?? "")
            }
    }

    /// Rows with an ingredient or kept as text have been decided; new/suggested have not.
    private var isDecided: Bool {
        row.ingredient != nil || row.keepAsText
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch row.state {
        case .resolved:
            resolvedContent(highlighted: false)
        case .highlighted:
            resolvedContent(highlighted: true)
        case .suggested:
            suggestedContent
        case .new:
            newContent
        case .text:
            textContent
        case .removed:
            removedContent
        }
    }

    /// Resolved: the canonical leads. Highlighted: the name as written leads and the
    /// warning dot says what it was matched to, so a fuzzy/embedding/medium match is
    /// never mistaken for a certainty (§4.2: highlighted = `warning` tone).
    private func resolvedContent(highlighted: Bool) -> some View {
        let canonical = model.displayName(for: row)
        return Button {
            sheet = .picker(addAlias: false)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(highlighted ? row.name : canonical)
                    .font(Theme.bodyFont(size: 17))
                    .foregroundStyle(palette.primaryText)
                amountLine(alsoShowingNameIfDifferentFrom: highlighted ? nil : canonical)
                if highlighted {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.warning)
                            .frame(width: 7, height: 7)
                        Text("matched to \(canonical)")
                            .font(Theme.bodyFont(size: 13))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Change ingredient")
    }

    /// The model's guess needs a human tap (§7.5): **Use** queues the alias; tapping
    /// the text opens the picker for anything else.
    private var suggestedContent: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                sheet = .picker(addAlias: true)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.name)
                        .font(emphasisFont(17))
                        .foregroundStyle(palette.primaryText)
                    amountLine(alsoShowingNameIfDifferentFrom: nil)
                    if let suggestion = row.suggestion {
                        Text("Looks like \(suggestion.canonicalName)")
                            .font(Theme.bodyFont(size: 14))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Pick a different ingredient")

            Button("Use", action: useSuggestion)
                .buttonStyle(.themedCTA(palette: palette, filled: true))
                .frame(width: 84)
                .accessibilityLabel("Use \(row.suggestion?.canonicalName ?? "the suggestion")")
        }
    }

    /// Nothing matched: Create (a custom canonical), Same as… (an alias), or Keep as
    /// text. Low model confidence adds the hint that the line may not be an
    /// ingredient at all — the swipe's **Not an ingredient** is the answer to that.
    private var newContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(emphasisFont(17))
                    .foregroundStyle(palette.primaryText)
                amountLine(alsoShowingNameIfDifferentFrom: nil)
                HStack(spacing: 6) {
                    Text("New ingredient")
                        .font(Theme.bodyFont(size: 13))
                        .foregroundStyle(Theme.warning)
                    if row.confidence == .low {
                        Text("· Might not be an ingredient")
                            .font(Theme.bodyFont(size: 13))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Create") { sheet = .category }
                    .buttonStyle(.themedCTA(palette: palette, filled: true))
                Button("Same as…") { sheet = .picker(addAlias: true) }
                    .buttonStyle(.themedCTA(palette: palette, filled: false))
                Button("Keep as text", action: keepAsText)
                    .buttonStyle(.themedCTA(palette: palette, filled: false))
            }
        }
    }

    private var textContent: some View {
        Button {
            sheet = .picker(addAlias: true)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(Theme.bodyFont(size: 17))
                    .foregroundStyle(palette.primaryText)
                amountLine(alsoShowingNameIfDifferentFrom: nil)
                Text("Kept as text")
                    .font(Theme.bodyFont(size: 13))
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Pick an ingredient instead")
    }

    private var removedContent: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.rawLine)
                    .font(Theme.bodyFont(size: 17))
                    .strikethrough()
                    .foregroundStyle(palette.secondaryText)
                Text("Not an ingredient")
                    .font(Theme.bodyFont(size: 13))
                    .foregroundStyle(palette.secondaryText.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore", action: restore)
                .buttonStyle(.themedCTA(palette: palette, filled: false))
                .frame(width: 96)
        }
    }

    // MARK: - Pieces

    /// "2 cups · diced" — quantity and unit from the row (never converted, §8), then
    /// the note. On a resolved row whose canonical differs from what was written, the
    /// written name rides along so "Vegetable broth" over a line that said "veggie
    /// stock" is visibly a mapping, not a rewrite (§1 "nothing silently dropped").
    @ViewBuilder
    private func amountLine(alsoShowingNameIfDifferentFrom canonical: String?) -> some View {
        let text = amountText(alsoShowingNameIfDifferentFrom: canonical)
        if !text.isEmpty {
            Text(text)
                .font(Theme.bodyFont(size: 14))
                .foregroundStyle(palette.secondaryText)
        }
    }

    private func amountText(alsoShowingNameIfDifferentFrom canonical: String?) -> String {
        var pieces: [String] = []
        let amount = QuantityFormat.string(quantity: row.quantity, unitKey: row.unitKey, unitText: row.unitText)
        if !amount.isEmpty { pieces.append(amount) }
        if let note = row.note, !note.isEmpty { pieces.append(note) }
        if let canonical = canonical,
           IngredientNormalizer.normalize(canonical) != IngredientNormalizer.normalize(row.name) {
            pieces.append("“\(row.name)”")
        }
        return pieces.joined(separator: " · ")
    }

    /// The design system's semibold weight axis on the chrome face — emphasis, not a
    /// display moment (the screen's one display moment is the recipe title).
    private func emphasisFont(_ size: CGFloat) -> Font {
        LFWTypography.font(.uiTitle, typeface: Theme.chromeTypeface, size: size)
    }

    // MARK: - Actions

    private func useSuggestion() {
        do {
            try model.useSuggestion(row.id)
            LFWHaptics.selection()
        } catch let error as AliasRefusal {
            LFWHaptics.warning()
            refusal = error
        } catch {
            LFWHaptics.warning()
        }
    }

    /// The picker's callback: throws so the sheet can show a refusal in place.
    private func apply(_ pick: IngredientPick, addAlias: Bool) throws {
        switch pick {
        case .existing(let id):
            try model.choose(row.id, ingredientID: id, addAlias: addAlias)
        case .pending(let id):
            model.choosePending(row.id, pendingID: id)
        case .create(let category):
            model.createIngredient(row.id, category: category)
        }
    }

    private func keepAsText() {
        model.keepAsText(row.id)
        LFWHaptics.selection()
    }

    private func removeRow() {
        model.remove(row.id)
        LFWHaptics.selection()
    }

    private func restore() {
        model.restore(row.id)
        LFWHaptics.selection()
    }
}

// MARK: - Edit sheet

/// Name, quantity, unit, note for one line, applied on **Done** (Cancel discards). The
/// raw line is shown read-only: it is never edited (§6). Quantity is typed as text
/// and read back through the app's own quantity grammar, so "1 1/2" and "½" work the
/// way they do in a pasted recipe; an unreadable quantity leaves the parsed value
/// alone rather than silently zeroing it. Picking a unit clears the as-written unit
/// text so display follows the key; leaving the unit untouched keeps the author's
/// spelling.
struct RowEditSheet: View {
    @ObservedObject var model: ConfirmModel
    let theme: LFWThemeConfig

    private let rowID: UUID
    private let rawLine: String
    private let originalUnitKey: String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var quantityText: String
    @State private var unitKey: String?
    @State private var note: String

    init(model: ConfirmModel, row: DraftRow, theme: LFWThemeConfig) {
        _model = ObservedObject(wrappedValue: model)
        self.theme = theme
        self.rowID = row.id
        self.rawLine = row.rawLine
        self.originalUnitKey = row.unitKey
        _name = State(initialValue: row.name)
        _quantityText = State(initialValue: row.quantity.map { QuantityFormat.string($0) } ?? "")
        _unitKey = State(initialValue: row.unitKey)
        _note = State(initialValue: row.note ?? "")
    }

    private var palette: LFWPaletteColors { theme.colors }

    var body: some View {
        NavigationStack {
            ThemedScreen(theme: theme) {
                Form {
                    Section {
                        Text(rawLine)
                            .font(Theme.bodyFont(size: 14))
                            .foregroundStyle(palette.secondaryText)
                    } header: {
                        header("Line as written")
                    }

                    Section {
                        TextField("Name", text: $name)
                            .font(Theme.bodyFont(size: 16))
                            .textInputAutocapitalization(.never)
                        TextField("Quantity", text: $quantityText)
                            .font(Theme.bodyFont(size: 16))
                            .keyboardType(.decimalPad)
                        Picker("Unit", selection: $unitKey) {
                            Text("None").tag(String?.none)
                            ForEach(UnitTable.all, id: \.key) { unit in
                                Text(unit.singular).tag(String?.some(unit.key))
                            }
                        }
                        .font(Theme.bodyFont(size: 16))
                        .tint(palette.accent)
                        TextField("Note", text: $note)
                            .font(Theme.bodyFont(size: 16))
                            .textInputAutocapitalization(.never)
                    } header: {
                        header("Fields")
                    }
                }
                .modifier(ThemedFormChrome(palette: palette))
                .foregroundStyle(palette.primaryText)
            }
            .navigationTitle("Edit line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        apply()
                        dismiss()
                    }
                }
            }
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(Theme.bodyFont(size: 12))
            .foregroundStyle(palette.secondaryText)
            .textCase(nil)
    }

    private func apply() {
        model.setName(rowID, name)
        let quantity = quantityText.trimmingCharacters(in: .whitespaces)
        if quantity.isEmpty {
            model.setQuantity(rowID, nil)
        } else if let value = Self.parseQuantity(quantity) {
            model.setQuantity(rowID, value)
        }
        if unitKey != originalUnitKey {
            model.setUnit(rowID, unitKey: unitKey, unitText: nil)
        }
        model.setNote(rowID, note)
        LFWHaptics.selection()
    }

    /// Plain decimals first (with a comma tolerated), then the recipe quantity
    /// grammar (§7.2) for fractions, mixed numbers and vulgar glyphs. Anything left
    /// over after the number means it was not a bare quantity.
    static func parseQuantity(_ text: String) -> Double? {
        if let direct = Double(text.replacingOccurrences(of: ",", with: ".")) {
            return direct
        }
        if let parsed = QuantityParser.parse(leading: text),
           parsed.remainder.trimmingCharacters(in: .whitespaces).isEmpty {
            return parsed.quantity.value
        }
        return nil
    }
}
