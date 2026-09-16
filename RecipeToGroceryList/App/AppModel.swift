import SwiftUI
import LFWDesignSystem

/// The three home destinations, in tab order (spec §4.1: List is first and the
/// default). Top-level rather than nested in a view so the order, titles and
/// symbols are unit-testable — the workout app's `AppTab` shape
/// (`WorkoutChatLog/App/RootTabView.swift` @5bffddfb80fc).
enum AppTab: Int, CaseIterable, Identifiable {
    case list, recipes, add

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .recipes: return "Recipes"
        case .add: return "Add"
        }
    }

    /// SF Symbol for the tab item.
    var icon: String {
        switch self {
        case .list: return "checklist"
        case .recipes: return "book.closed"
        case .add: return "plus.circle"
        }
    }
}

/// What the Share Extension handed us (§5.1), waiting for the Add screen to pick it
/// up and run the matching import path. Set by `AppModel.drainInbox()`, consumed
/// (set back to nil) by `AddView`.
enum PendingImport: Equatable {
    case url(URL)
    case text(String)
}

/// The app's single source of UI state, layered over the one `RecipeStore` and the
/// tiny `SettingsStore`. Screens read the store through it and observe
/// `changeToken` to reload after any write, so no screen ever caches rows the
/// store no longer has. Shape copied from `WordOfTheDay/App/AppModel.swift` at
/// `a-new-word-every-day@e829bcc9c0dc` (theme + onboarding + tab selection over an
/// injectable store), with the workout app's store-first composition
/// (`WorkoutChatLogApp.swift` @5bffddfb80fc: one store, built at launch).
///
/// `@MainActor` because it drives the store's mutating APIs, which carry the
/// single-connection write invariant (`RecipeStore` writes are `@MainActor`).
@MainActor
final class AppModel: ObservableObject {
    let store: RecipeStore
    let settings: SettingsStore

    @Published var theme: LFWThemeConfig
    @Published private(set) var onboardingComplete: Bool
    @Published var selectedTab: AppTab = .list
    /// Bumped after every store write. Screens `.onChange(of:)` this to reload; the
    /// list is a pure function of the store (§9), so this is the only signal needed.
    @Published private(set) var changeToken: Int = 0
    /// The shared link or text waiting for the Add screen. nil when nothing is pending.
    @Published var pendingImport: PendingImport?

    /// Layer 3 of resolution (§7.4), opportunistic: the no-op when NaturalLanguage
    /// isn't available. Held here so one instance's model assets serve every parse.
    let embedding: IngredientEmbedding
    /// Whether the on-device model can be used *right now* (§7.6 copy keys off this).
    let onDeviceAIAvailable: Bool

    private let inbox: ShareInbox?

    /// Canonical vectors embedded once per index — rebuilt when a save adds a
    /// canonical (entry count changes) or when embeddings become ready. Never caches
    /// an empty set, so layer 3 can't be frozen off (`SemanticCandidateSet.build`
    /// returns nil until the embedding is ready).
    private var semanticCache: SemanticCandidateSet?
    private var semanticCacheEntryCount: Int = -1

    init(store: RecipeStore,
         settings: SettingsStore = .shared,
         embedding: IngredientEmbedding = IngredientEmbeddingFactory.make(),
         inbox: ShareInbox? = ShareInbox.appGroup()) {
        #if DEBUG
        Self.applyUITestLaunchOverrides(to: settings)
        #endif
        self.store = store
        self.settings = settings
        self.embedding = embedding
        self.inbox = inbox
        self.onDeviceAIAvailable = RecipeParserFactory.onDeviceAIAvailable
        self.theme = settings.theme
        self.onboardingComplete = settings.onboardingComplete
        #if DEBUG
        applyLaunchOverrides()
        #endif
    }

    // MARK: Theme

    /// Apply a theme. Sanitized through the settings store so an unbundled face can
    /// never reach the published value either.
    func setTheme(_ config: LFWThemeConfig) {
        let clean = SettingsStore.sanitized(config)
        theme = clean
        settings.theme = clean
    }

    // MARK: Onboarding

    func completeOnboarding() {
        settings.onboardingComplete = true
        onboardingComplete = true
    }

    // MARK: Writes

    /// Call after every store write. Wrapping-add so a very long session can't trap.
    func didWrite() {
        changeToken &+= 1
    }

    /// The one way a recipe lands from the UI: `RecipeStore.save` (validate →
    /// transaction → rows), then the reload signal, then the success haptic (§4.2).
    /// Throws `RecipeValidationError` / `RecipeStoreError.aliasOwnedElsewhere`
    /// untouched so Confirm can show the refusal; nothing is bumped on failure.
    @discardableResult
    func saveRecipe(_ draft: RecipeDraft) throws -> Int64 {
        let id = try store.save(draft)
        didWrite()
        LFWHaptics.success()
        return id
    }

    // MARK: Share Extension inbox (§5.1)

    /// Called on every `scenePhase == .active`. The first shared item becomes
    /// `pendingImport` and the Add tab comes to the front; any further items are put
    /// back in the inbox for the next foreground so nothing the user shared is
    /// silently dropped (§1). A read failure leaves the UI untouched — the inbox is
    /// a convenience, never a reason to block launch.
    func drainInbox() {
        guard let inbox else { return }
        let items: [SharedInboxItem]
        do {
            items = try inbox.drain()
        } catch {
            return
        }
        guard let first = items.first else { return }
        for item in items.dropFirst() {
            _ = try? inbox.append(item)
        }
        pendingImport = Self.makePendingImport(from: first)
        selectedTab = .add
    }

    /// A URL item whose value parses is `.url`; anything else (a text item, or a URL
    /// item the extension couldn't have validated) is `.text`, so the Paste path can
    /// still make something of it.
    static func makePendingImport(from item: SharedInboxItem) -> PendingImport {
        if item.kind == .url,
           let url = URL(string: item.value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return .url(url)
        }
        return .text(item.value)
    }

    // MARK: Parsing (§7)

    /// A pipeline over a fresh snapshot of the ingredient registry. Built per parse
    /// so a canonical created by the previous save is known to the next one; the
    /// semantic candidate set is the only cached part (see `semanticCache`).
    func makePipeline() throws -> RecipePipeline {
        let index = try store.ingredientIndex()
        let resolver = IngredientResolver(index: index,
                                          embedding: embedding,
                                          semantic: semanticCandidates(for: index))
        return RecipePipeline(resolver: resolver, refiner: RecipeParserFactory.makeRefiner())
    }

    private func semanticCandidates(for index: IngredientIndex) -> SemanticCandidateSet? {
        guard embedding.isReady else { return nil }
        if let cached = semanticCache, semanticCacheEntryCount == index.entries.count {
            return cached
        }
        guard let built = SemanticCandidateSet.build(index: index, embedding: embedding) else { return nil }
        semanticCache = built
        semanticCacheEntryCount = index.entries.count
        return built
    }

    // MARK: Launch arguments (DEBUG only)

    #if DEBUG
    /// UI-test / screenshot launch flags, the word app's set
    /// (`WordOfTheDay/App/AppModel.swift` `applyUITestLaunchOverrides`):
    /// `-UITestResetOnboarding` clears persisted settings so each run starts at the
    /// onboarding gate; `-UITestSkipOnboarding` jumps straight to the tab shell
    /// (after the reset).
    private static func applyUITestLaunchOverrides(to settings: SettingsStore) {
        let args = Set(ProcessInfo.processInfo.arguments)
        guard args.contains("-UITestResetOnboarding") || args.contains("-UITestSkipOnboarding") else { return }
        settings.reset()
        if args.contains("-UITestSkipOnboarding") {
            settings.onboardingComplete = true
        }
    }

    /// `-ScreenshotDemo` seeds two recipes and a list through the real write path;
    /// `-OpenTabRecipes` / `-OpenTabAdd` start on that tab (the capture script's
    /// three shots: `scripts/capture_app_store_screenshots.sh`).
    private func applyLaunchOverrides() {
        let args = Set(ProcessInfo.processInfo.arguments)
        if args.contains("-ScreenshotDemo") {
            do {
                try ScreenshotDemoSeeder.seed(into: store)
                didWrite()
            } catch {
                print("[RecipeToGroceryList] screenshot demo seed failed: \(error)")
            }
        }
        if args.contains("-OpenTabRecipes") {
            selectedTab = .recipes
        } else if args.contains("-OpenTabAdd") {
            selectedTab = .add
        }
    }
    #endif
}

#if DEBUG
/// Polished on-device state for App Store screenshots (the word app's
/// `ScreenshotDemoSeeder` idea, `WordOfTheDay/App/ScreenshotDemoSeeder.swift`
/// @e829bcc9c0dc). Goes through `RecipeStore.save` like every other recipe — no
/// pipeline, no model: the drafts are built by hand and each row is resolved with
/// the registry's exact-name match, so the demo can never write anything the
/// Confirm screen couldn't. Idempotent: a second launch with the flag (the capture
/// script launches once per shot) seeds nothing when recipes already exist.
enum ScreenshotDemoSeeder {
    struct Line {
        let raw: String
        let name: String
        /// The seed canonical this line should land on (`IngredientIndex.exactMatch`).
        let canonical: String
        let quantity: Double?
        let unitKey: String?
        let unitText: String?
        let note: String?

        init(_ raw: String, name: String, canonical: String,
             quantity: Double? = nil, unitKey: String? = nil, unitText: String? = nil, note: String? = nil) {
            self.raw = raw
            self.name = name
            self.canonical = canonical
            self.quantity = quantity
            self.unitKey = unitKey
            self.unitText = unitText
            self.note = note
        }
    }

    /// Two recipes that share broth, onion and garlic, so the list shows both the
    /// §8 sum ("→ 5 cloves") and the no-sum case, plus one manual item.
    static let lentilSoup: [Line] = [
        Line("2 tbsp olive oil", name: "olive oil", canonical: "Olive oil", quantity: 2, unitKey: "tbsp", unitText: "tbsp"),
        Line("1 onion, diced", name: "onion", canonical: "Onion", quantity: 1, note: "diced"),
        Line("2 carrots, chopped", name: "carrots", canonical: "Carrot", quantity: 2, note: "chopped"),
        Line("3 cloves garlic, minced", name: "garlic", canonical: "Garlic", quantity: 3, unitKey: "clove", unitText: "cloves", note: "minced"),
        Line("1 cup red lentils", name: "red lentils", canonical: "Red lentil", quantity: 1, unitKey: "cup", unitText: "cup"),
        Line("4 cups vegetable broth", name: "vegetable broth", canonical: "Vegetable broth", quantity: 4, unitKey: "cup", unitText: "cups"),
        Line("1 tsp ground cumin", name: "ground cumin", canonical: "Ground cumin", quantity: 1, unitKey: "tsp", unitText: "tsp"),
        Line("1 bay leaf", name: "bay leaf", canonical: "Bay leaf", quantity: 1),
        Line("1 lemon", name: "lemon", canonical: "Lemon", quantity: 1),
        Line("Salt and pepper, to taste", name: "salt and pepper", canonical: "Salt and pepper", note: "to taste"),
    ]

    static let mushroomRisotto: [Line] = [
        Line("1½ cups arborio rice", name: "arborio rice", canonical: "Arborio rice", quantity: 1.5, unitKey: "cup", unitText: "cups"),
        Line("4 cups vegetable broth", name: "vegetable broth", canonical: "Vegetable broth", quantity: 4, unitKey: "cup", unitText: "cups"),
        Line("8 oz mushrooms, sliced", name: "mushrooms", canonical: "Mushroom", quantity: 8, unitKey: "oz", unitText: "oz", note: "sliced"),
        Line("1 onion, finely chopped", name: "onion", canonical: "Onion", quantity: 1, note: "finely chopped"),
        Line("2 cloves garlic", name: "garlic", canonical: "Garlic", quantity: 2, unitKey: "clove", unitText: "cloves"),
        Line("2 tbsp butter", name: "butter", canonical: "Butter", quantity: 2, unitKey: "tbsp", unitText: "tbsp"),
        Line("½ cup dry white wine", name: "dry white wine", canonical: "Dry white wine", quantity: 0.5, unitKey: "cup", unitText: "cup"),
        Line("½ cup grated parmesan", name: "parmesan", canonical: "Parmesan cheese", quantity: 0.5, unitKey: "cup", unitText: "cup", note: "grated"),
        Line("Chopped parsley, for serving", name: "parsley", canonical: "Parsley", note: "chopped, for serving"),
    ]

    @MainActor
    static func seed(into store: RecipeStore) throws {
        guard try store.recipes().isEmpty else { return }
        let index = try store.ingredientIndex()
        let soup = try store.save(draft(title: "Lentil soup",
                                        source: RecipeSource(kind: .text),
                                        lines: lentilSoup,
                                        index: index))
        let risotto = try store.save(draft(title: "Mushroom risotto",
                                           source: RecipeSource(kind: .url,
                                                                ref: "https://example.com/recipes/mushroom-risotto",
                                                                servingsText: "Serves 4"),
                                           lines: mushroomRisotto,
                                           index: index))
        try store.setSelected(soup, true)
        try store.setSelected(risotto, true)
        try store.addManualItem("Coffee")
    }

    /// A line whose canonical the seed no longer has is kept as text rather than
    /// failing the whole demo — the same choice the user has in Confirm.
    static func draft(title: String, source: RecipeSource, lines: [Line], index: IngredientIndex) -> RecipeDraft {
        var rows: [DraftRow] = []
        rows.reserveCapacity(lines.count)
        for (position, line) in lines.enumerated() {
            var row = DraftRow(lineIndex: position,
                               rawLine: line.raw,
                               name: line.name,
                               quantity: line.quantity,
                               unitKey: line.unitKey,
                               unitText: line.unitText,
                               note: line.note)
            if let id = index.exactMatch(line.canonical) {
                row.ingredient = .existing(id)
                row.ingredientName = index.entry(id: id)?.canonicalName ?? line.canonical
                row.resolution = .exact
            } else {
                row.keepAsText = true
                row.resolution = .none
            }
            rows.append(row)
        }
        return RecipeDraft(title: title, source: source, rawLines: lines.map(\.raw), rows: rows)
    }
}
#endif
