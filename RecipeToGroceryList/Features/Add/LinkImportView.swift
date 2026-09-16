import SwiftUI
import LFWDesignSystem

/// A pasted link (spec §5.1) — the app's only network call, and it happens exactly
/// once per tap: validate (`https` only), one GET through `RecipeFetchPolicy`'s rules,
/// extract schema.org `Recipe` data from the HTML, hand the ingredient lines to the
/// pipeline. The page is parsed once and discarded; only its lines reach Confirm.
///
/// There are no automatic retries: every failure is shown with its own words and a
/// **Try again** button, so a second request is always a second tap. A page with no
/// recipe data gets the §5.1 empty state with its two ways out.
///
/// `fetcher` is injected (`PageFetching`) so a preview or test can stand in for the
/// network; the default is the real `RecipeFetcher`.
///
/// The idle / loading / failed / empty phases follow the workout app's photo capture
/// screen (`WorkoutChatLog/Features/OCRCaptureView.swift` at `workout-logger@5bffddfb80fc`:
/// one `enum` phase driving the body, errors shown in place with a retry button); the
/// empty state is the family `LFWEmptyState` as the word app uses it.
struct LinkImportView: View {
    @EnvironmentObject private var appModel: AppModel
    let fetcher: PageFetching
    let onParsed: (ParsedRecipe) -> Void
    /// The empty state's "Paste the ingredients instead" (the parent routes to Paste).
    let onPasteInstead: () -> Void

    @State private var urlText: String
    @State private var phase: Phase = .idle
    @State private var fetchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private enum Phase: Equatable {
        case idle
        case fetching
        /// Validation or fetch failure, in the policy's words; shown with Try again.
        case failed(String)
        /// The page downloaded but had no recipe data (§5.1 step 3).
        case noRecipe(URL)
    }

    init(prefill: String = "",
         fetcher: PageFetching = RecipeFetcher(),
         onParsed: @escaping (ParsedRecipe) -> Void,
         onPasteInstead: @escaping () -> Void) {
        _urlText = State(initialValue: prefill)
        self.fetcher = fetcher
        self.onParsed = onParsed
        self.onPasteInstead = onPasteInstead
    }

    private var palette: LFWPaletteColors { appModel.theme.colors }

    private var isBlank: Bool {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ThemedScreen(theme: appModel.theme) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field

                    // The privacy sentence, verbatim from §5.1 / docs/privacy.md.
                    Text("The app downloads that page, once, and nothing else.")
                        .font(Theme.bodyFont(size: 13))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    status

                    if case .noRecipe = phase {
                        EmptyView()
                    } else {
                        Button(action: fetch) {
                            Text("Fetch")
                        }
                        .buttonStyle(LFWCTAButtonStyle())
                        .disabled(phase == .fetching || isBlank)
                        .opacity(isBlank ? 0.55 : 1)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle("Link")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            // Leaving the screen abandons the request; nothing is retried on return.
            fetchTask?.cancel()
            fetchTask = nil
        }
    }

    private var field: some View {
        TextField("https://…", text: $urlText)
            .font(Theme.bodyFont(size: 16))
            .foregroundStyle(palette.primaryText)
            .keyboardType(.URL)
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit(fetch)
            .focused($fieldFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: LFWRadius.surface, style: .continuous)
                    .fill(palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LFWRadius.surface, style: .continuous)
                    .strokeBorder(palette.primaryText.opacity(0.12), lineWidth: 1)
            )
            .accessibilityLabel("Recipe link")
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .fetching:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(palette.accent)
                Text("Downloading the page…")
                    .font(Theme.bodyFont(size: 14))
                    .foregroundStyle(palette.secondaryText)
            }
            .padding(.vertical, 4)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Theme.bodyFont(size: 14))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again", action: fetch)
                    .buttonStyle(.themedCTA(palette: palette, filled: false))
            }
            .padding(.vertical, 4)
        case .noRecipe(let url):
            noRecipe(url)
        }
    }

    /// §5.1 step 3: nothing found → the family empty state with the two exits the
    /// spec names. Paste opens with nothing prefilled (we never keep the page).
    private func noRecipe(_ url: URL) -> some View {
        LFWEmptyState(symbol: "doc.questionmark",
                      title: "Couldn't find a recipe on this page",
                      message: "The page has no recipe data the app can read.",
                      accent: palette.accent) {
            VStack(spacing: 10) {
                Button("Paste the ingredients instead", action: onPasteInstead)
                    .buttonStyle(LFWCTAButtonStyle())
                Link(destination: url) {
                    Text("Open in Safari")
                }
                .buttonStyle(.themedCTA(palette: palette, filled: false))
                Button("Try another link") {
                    phase = .idle
                    fieldFocused = true
                }
                .font(Theme.bodyFont(size: 14))
                .foregroundStyle(palette.secondaryText)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Fetch (one tap, one request)

    private func fetch() {
        guard phase != .fetching, !isBlank else { return }
        fieldFocused = false
        switch RecipeFetchPolicy.validate(urlText) {
        case .failure(let error):
            // http, no host, garbage: refused before any request is made.
            phase = .failed(error.message)
        case .success(let url):
            phase = .fetching
            fetchTask = Task { @MainActor in
                await download(url)
            }
        }
    }

    private func download(_ url: URL) async {
        do {
            let page = try await fetcher.fetch(url)
            guard !Task.isCancelled else { return }
            guard let extracted = RecipeHTMLExtractor.extract(from: page.html) else {
                phase = .noRecipe(page.finalURL)
                return
            }
            let pipeline = try appModel.makePipeline()
            let source = RecipeSource(kind: .url,
                                      ref: page.finalURL.absoluteString,   // final URL after redirects (§5.1)
                                      titleGuess: extracted.title,
                                      servingsText: extracted.servingsText)
            let outcome = await pipeline.run(lines: extracted.ingredientLines, source: source)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .draft(let parsed):
                phase = .idle
                onParsed(parsed)
            case .declined(let reason):
                phase = .failed(reason.message)
            }
        } catch let error as RecipeFetchError {
            guard !Task.isCancelled else { return }
            phase = .failed(error.message)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed("The page couldn't be downloaded. Check the link and try again.")
        }
    }
}
