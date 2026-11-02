import SwiftUI
import PhotosUI
import LFWDesignSystem

/// The photo path (spec §5.3): pick or take one photo of a page, read it with
/// on-device Vision, and hand the recognized lines to the same pipeline every
/// other capture path uses. The image is processed in memory and never stored —
/// the copy under the buttons says so, and the privacy screen says it in the same
/// words.
///
/// The weakest of the three paths, and the spec is honest about why: multi-column
/// cookbook layouts interleave, drop caps confuse the merge, and a run-on line
/// can't be split. After the page is read, the picture stays up and the proposed
/// ingredient lines are checked. Headings and steps stay off the list. Confirm
/// is where a checked line's quantity or match is fixed.
///
/// Structure mirrors `PasteImportView` so the three Add screens read as one set;
/// the phase machine and the latest-request-wins generation counter come from
/// `WorkoutChatLog/Features/OCRCaptureModel.swift` at `workout-logger@5bffddfb80fc`
/// (picking a second photo before the first finishes must not let the older read
/// overwrite the newer one).
struct PhotoImportView: View {
    @EnvironmentObject private var appModel: AppModel
    let onParsed: (ParsedRecipe) -> Void
    let recognizer: TextRecognizing

    private struct Review: Equatable {
        var imageData: Data
        var lines: [RecognizedLine]
        var included: Set<Int>
    }

    private enum Phase: Equatable {
        case idle
        case recognizing
        case review(Review)
        case empty
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var isParsing = false
    /// Monotonic token: a read only applies if it is still the newest one.
    @State private var generation = 0

    init(onParsed: @escaping (ParsedRecipe) -> Void,
         recognizer: TextRecognizing = TextRecognizerFactory.make()) {
        self.onParsed = onParsed
        self.recognizer = recognizer
    }

    private var palette: LFWPaletteColors { appModel.theme.colors }

    var body: some View {
        ThemedScreen(theme: appModel.theme) {
            content
                .padding(20)
        }
        .navigationTitle(isReviewing ? "Choose ingredients" : "Photo")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            load(item)
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showingCamera) {
            PhotoCamera { data in
                showingCamera = false
                guard let data else { return }
                Task { await read(data) }
            }
            .ignoresSafeArea()
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            picker
        case .recognizing:
            VStack(spacing: 12) {
                ProgressView()
                    .tint(palette.primaryText)
                Text("Reading the page…")
                    .font(Theme.bodyFont(size: 14))
                    .foregroundStyle(palette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review(let review):
            PhotoLineReview(imageData: review.imageData,
                            lines: review.lines,
                            included: includedBinding,
                            palette: palette,
                            isParsing: isParsing,
                            onUse: useSelection,
                            onDifferentPhoto: { phase = .idle })
        case .empty:
            LFWEmptyState(symbol: "doc.text.viewfinder",
                          title: "Couldn't read that photo",
                          message: "Try a clearer, well-lit photo of a single column of ingredients.",
                          accent: palette.accent) {
                Button("Try another") { phase = .idle }
                    .buttonStyle(.themedCTA(palette: palette, filled: false))
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            LFWEmptyState(symbol: "exclamationmark.triangle",
                          title: message,
                          message: "Nothing was saved. Pick another photo to try again.",
                          accent: Theme.warning) {
                Button("Choose another photo") { phase = .idle }
                    .buttonStyle(.themedCTA(palette: palette, filled: false))
                    .frame(maxWidth: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 8)

            PhotosPicker(selection: $photoItem, matching: .images) {
                Text("Choose a photo")
            }
            .buttonStyle(LFWCTAButtonStyle())

            #if canImport(UIKit)
            if PhotoCamera.isAvailable {
                Button("Take a photo") { showingCamera = true }
                    .buttonStyle(LFWCTAButtonStyle(filled: false))
            }
            #endif

            Text("Works best on a single column of ingredients. You'll choose which lines are ingredients. The photo is read on this phone and never stored.")
                .font(Theme.bodyFont(size: 13))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Loads the picked asset's bytes, then reads it. The selection is cleared
    /// either way so re-picking the same photo fires `onChange` again.
    private func load(_ item: PhotosPickerItem) {
        Task { @MainActor in
            defer { photoItem = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    phase = .failed("Couldn't load that image. Try another photo.")
                    return
                }
                await read(data)
            } catch {
                phase = .failed("Couldn't load that image. Try another photo.")
            }
        }
    }

    /// Recognize, then show the checklist. Parsing waits until she taps Use.
    /// Every resume checks the generation token, so a slower earlier photo can
    /// never overwrite a newer pick.
    @MainActor
    private func read(_ imageData: Data) async {
        generation += 1
        let token = generation
        phase = .recognizing

        let lines = await recognizer.recognizePage(in: imageData)
        guard token == generation else { return }
        guard !lines.isEmpty else {
            phase = .empty
            return
        }
        let roles = IngredientBlock.propose(lines.map(\.text))
        let included = Set(roles.enumerated().compactMap { index, role in
            role == .ingredient ? index : nil
        })
        phase = .review(Review(imageData: imageData, lines: lines, included: included))
    }

    /// The checklist lives inside `Phase`, so the binding writes the whole phase back.
    private var includedBinding: Binding<Set<Int>> {
        Binding {
            if case .review(let review) = phase { return review.included }
            return []
        } set: { newValue in
            if case .review(var review) = phase {
                review.included = newValue
                phase = .review(review)
            }
        }
    }

    private var isReviewing: Bool {
        if case .review = phase { return true }
        return false
    }

    /// Parse only the checked lines. Unchecked text stays on this screen, which
    /// remains under Confirm, so it can be put back without being shopped.
    /// A line she checked is kept even when the model is unsure.
    private func useSelection() {
        guard case .review(let review) = phase, !review.included.isEmpty, !isParsing else { return }
        isParsing = true
        let lines = review.lines.map(\.text)
        let included = review.included
        Task { @MainActor in
            defer { isParsing = false }
            do {
                let pipeline = try appModel.makePipeline()
                let outcome = await pipeline.run(lines: lines,
                                                  source: RecipeSource(kind: .photo),
                                                  selection: .indices(included),
                                                  droppingUncertainLines: false)
                switch outcome {
                case .draft(let parsed):
                    onParsed(parsed)
                case .declined(let reason):
                    phase = .failed(reason.message)
                }
            } catch {
                phase = .failed("The ingredient library couldn't be read. Try again.")
            }
        }
    }
}
