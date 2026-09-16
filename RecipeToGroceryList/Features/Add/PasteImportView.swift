import SwiftUI
import LFWDesignSystem

/// Pasted text (spec §5.2): one editor, one **Parse** pill. The pipeline does the
/// splitting, bullet stripping and header detection; this view only hands it the
/// text with a `.text` source and no title guess — Confirm asks for the title, because
/// guessing it from the first line would be exactly the kind of silent invention the
/// spec forbids. A declined parse (nothing but headers, or nothing at all) is shown
/// inline in the decline's own words.
///
/// Accepts a prefill so text shared through the extension lands ready to parse.
///
/// Flow copied from the workout app's input box (`WorkoutChatLog/Features/TodayView.swift`
/// at `workout-logger@5bffddfb80fc`: type → one parse tap → a confirm card, with the
/// parse awaited in a `Task` so the model never blocks the editor); the editor chrome
/// is the word app's themed surface (`palette.surface` on `LFWRadius.surface`).
struct PasteImportView: View {
    @EnvironmentObject private var appModel: AppModel
    let onParsed: (ParsedRecipe) -> Void

    @State private var text: String
    @State private var message: String?
    @State private var isParsing = false
    @FocusState private var editorFocused: Bool

    init(prefill: String = "", onParsed: @escaping (ParsedRecipe) -> Void) {
        _text = State(initialValue: prefill)
        self.onParsed = onParsed
    }

    private var palette: LFWPaletteColors { appModel.theme.colors }

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ThemedScreen(theme: appModel.theme) {
            VStack(alignment: .leading, spacing: 14) {
                editor
                    .frame(minHeight: 200, maxHeight: .infinity)

                Text("One ingredient per line. A line ending in a colon, like “For the sauce:”, is treated as a section header.")
                    .font(Theme.bodyFont(size: 13))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let message = message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(Theme.bodyFont(size: 14))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: parse) {
                    if isParsing {
                        ProgressView()
                            .tint(LFWColors.deepSea)
                    } else {
                        Text("Parse")
                    }
                }
                .buttonStyle(LFWCTAButtonStyle())
                .disabled(isParsing || isBlank)
                .opacity(isBlank ? 0.55 : 1)
            }
            .padding(20)
        }
        .navigationTitle("Paste")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .keyboard) {
                Button("Done") { editorFocused = false }
                    .tint(palette.accent)
            }
        }
    }

    /// `TextEditor` has no placeholder of its own; the overlay disappears with the
    /// first character and never intercepts taps.
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(Theme.bodyFont(size: 16))
                .foregroundStyle(palette.primaryText)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($editorFocused)
                .padding(10)
            if text.isEmpty {
                Text("Paste the ingredient list…")
                    .font(Theme.bodyFont(size: 16))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: LFWRadius.surface, style: .continuous)
                .fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LFWRadius.surface, style: .continuous)
                .strokeBorder(palette.primaryText.opacity(0.12), lineWidth: 1)
        )
    }

    /// One pipeline per parse over a fresh registry snapshot (`AppModel.makePipeline`),
    /// awaited off the button so a slow on-device model never freezes the editor.
    private func parse() {
        guard !isParsing, !isBlank else { return }
        isParsing = true
        message = nil
        editorFocused = false
        let input = text
        Task { @MainActor in
            defer { isParsing = false }
            do {
                let pipeline = try appModel.makePipeline()
                let outcome = await pipeline.run(text: input, source: RecipeSource(kind: .text))
                switch outcome {
                case .draft(let parsed):
                    onParsed(parsed)
                case .declined(let reason):
                    message = reason.message
                }
            } catch {
                message = "The ingredient library couldn't be read. Try again."
            }
        }
    }
}
