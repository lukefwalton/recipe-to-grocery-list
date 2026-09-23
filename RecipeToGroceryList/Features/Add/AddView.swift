import SwiftUI
import LFWDesignSystem

/// The Add tab (spec §4.1): three entries — Link, Paste, Photo — each of which
/// produces a `ParsedRecipe` and lands on the same Confirm screen. Navigation lives
/// here, in one `NavigationStack` path, so the import views stay callback-based and
/// Confirm's "saved" callback can pop to the root and switch to the Recipes tab.
///
/// The Share Extension's inbox arrives as `AppModel.pendingImport` (§5.1): this view
/// consumes it — a URL opens Link prefilled, text opens Paste prefilled — and clears
/// it, so a shared item is handled exactly once.
///
/// Shape: the word app's `PracticeView` (`ThemedScreen` around a `NavigationStack`,
/// `WordOfTheDay/Features/Practice/PracticeView.swift` at
/// `a-new-word-every-day@e829bcc9c0dc`) with a hero header in the display face and
/// the spec's three `LFWCTAButtonStyle` entries.
struct AddView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var path: [Route] = []
    @State private var linkPrefill = ""
    @State private var pastePrefill = ""

    /// Where the Add flow can go. `ParsedRecipe` is `Equatable` but not `Hashable`
    /// (it carries `Double?` quantities and nested arrays the draft never needs to
    /// hash), so the Confirm destination wraps it in an identity token.
    enum Route: Hashable {
        case link
        case paste
        case photo
        case confirm(ConfirmToken)
    }

    private var palette: LFWPaletteColors { appModel.theme.colors }

    var body: some View {
        ThemedScreen(theme: appModel.theme) {
            NavigationStack(path: $path) {
                menu
                    .navigationDestination(for: Route.self) { route in
                        destination(route)
                    }
            }
        }
        .onAppear(perform: consumePendingImport)
        .onChange(of: appModel.pendingImport) { _, _ in
            consumePendingImport()
        }
    }

    // MARK: - Menu

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Add a recipe")
                        .font(Theme.displayFont(appModel.theme, size: 32))
                        .foregroundStyle(palette.primaryText)
                    Text("Paste a link or the ingredient list, or photograph a page. You confirm every row before anything is saved.")
                        .font(Theme.bodyFont(size: 15))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    Button {
                        path.append(.link)
                    } label: {
                        Label("Link", systemImage: SourceKind.url.symbol)
                    }
                    .buttonStyle(LFWCTAButtonStyle())

                    Button {
                        path.append(.paste)
                    } label: {
                        Label("Paste", systemImage: SourceKind.text.symbol)
                    }
                    .buttonStyle(LFWCTAButtonStyle())

                    Button {
                        path.append(.photo)
                    } label: {
                        Label("Photo", systemImage: SourceKind.photo.symbol)
                    }
                    .buttonStyle(LFWCTAButtonStyle())
                }

                if !appModel.onDeviceAIAvailable {
                    // §7.6: the same words on every screen that mentions the model.
                    Text(RecipeParserFactory.unavailableCopy)
                        .font(Theme.bodyFont(size: 13))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Destinations

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .link:
            LinkImportView(prefill: linkPrefill, onParsed: showConfirm) {
                pastePrefill = ""
                path.append(.paste)
            }
            // A new shared link while Link is already showing must replace the field,
            // so the view's identity follows the prefill.
            .id("link-\(linkPrefill)")
        case .paste:
            PasteImportView(prefill: pastePrefill, onParsed: showConfirm)
                .id("paste-\(pastePrefill)")
        case .photo:
            PhotoImportView(onParsed: showConfirm)
        case .confirm(let token):
            ConfirmView(parsed: token.parsed, index: confirmIndex(), onSaved: finish)
        }
    }

    private func showConfirm(_ parsed: ParsedRecipe) {
        path.append(.confirm(ConfirmToken(parsed: parsed)))
    }

    /// Saved: back to the tab's root and over to Recipes, where the new recipe sits
    /// at the top waiting for its "cooking this" toggle.
    private func finish(_ recipeID: Int64) {
        path = []
        appModel.selectedTab = .recipes
    }

    /// The registry snapshot Confirm checks aliases against. A typed store read (never
    /// SQL from a view); on the unlikely read failure Confirm still works with an
    /// empty index — rows keep their names and every decision remains possible.
    private func confirmIndex() -> IngredientIndex {
        (try? appModel.store.ingredientIndex()) ?? IngredientIndex.empty
    }

    // MARK: - Share Extension inbox (§5.1)

    private func consumePendingImport() {
        guard let pending = appModel.pendingImport else { return }
        appModel.pendingImport = nil
        switch pending {
        case .url(let url):
            linkPrefill = url.absoluteString
            pastePrefill = ""
            path = [.link]
        case .text(let text):
            pastePrefill = text
            linkPrefill = ""
            path = [.paste]
        }
    }
}

/// Identity for a Confirm push. Two pushes of equal drafts are still two different
/// screens, so equality and hashing are by `id`, not by content.
struct ConfirmToken: Hashable {
    let id = UUID()
    let parsed: ParsedRecipe

    static func == (lhs: ConfirmToken, rhs: ConfirmToken) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
