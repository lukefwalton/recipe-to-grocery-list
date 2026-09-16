import XCTest
import LFWDesignSystem
@testable import RecipeToGroceryList

/// `AppModel` over a real temp-file store, a throwaway settings suite and a
/// `ShareInbox` in a temp directory: the reload token, onboarding and theme
/// persistence, the inbox drain (§5.1), the per-parse pipeline and the one save
/// path. `@MainActor` because the model and the store's writes are.
@MainActor
final class AppModelTests: XCTestCase {

    private var dbPath: String!
    private var store: RecipeStore!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var inboxDirectory: URL!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "rtg-appmodel-\(UUID().uuidString).sqlite"
        store = RecipeStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
        try store.seedIngredientsIfNeeded(IngredientSeed.load(from: Bundle(for: Self.self)))

        suiteName = "rtg-appmodel-settings-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsStore(defaults: defaults)

        inboxDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rtg-inbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        store = nil   // close the connection before deleting files
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: inboxDirectory)
    }

    // MARK: - Helpers

    private func makeModel(embedding: IngredientEmbedding = NoopEmbedding(), inbox: ShareInbox? = nil) -> AppModel {
        AppModel(store: store, settings: settings, embedding: embedding, inbox: inbox)
    }

    /// A one-row draft resolved against the real seed, the way Confirm would hand it over.
    private func garlicDraft(title: String) throws -> RecipeDraft {
        let index = try store.ingredientIndex()
        let garlic = try XCTUnwrap(index.exactMatch("Garlic"), "the bundled seed has Garlic")
        let row = DraftRow(lineIndex: 0,
                           rawLine: "3 cloves garlic",
                           name: "garlic",
                           quantity: 3,
                           unitKey: "clove",
                           unitText: "cloves",
                           ingredient: .existing(garlic),
                           ingredientName: "Garlic",
                           resolution: .exact)
        return RecipeDraft(title: title, source: RecipeSource(kind: .text), rawLines: ["3 cloves garlic"], rows: [row])
    }

    // MARK: - Initial state

    func testInitialState() {
        let model = makeModel()
        XCTAssertEqual(model.selectedTab, .list, "§4.1: List is the default tab")
        XCTAssertEqual(model.changeToken, 0)
        XCTAssertNil(model.pendingImport)
        XCTAssertFalse(model.onboardingComplete)
        XCTAssertEqual(model.theme, LFWThemeConfig.default)
        XCTAssertTrue(model.store === store)
    }

    func testInitialStateReadsTheInjectedSettings() {
        settings.onboardingComplete = true
        settings.theme = LFWThemeConfig(typeface: .inter, palette: .paper, accentHueShift: 15)
        let model = makeModel()
        XCTAssertTrue(model.onboardingComplete)
        XCTAssertEqual(model.theme.typeface, .inter)
        XCTAssertEqual(model.theme.palette, .paper)
    }

    // MARK: - Reload token

    func testDidWriteBumpsTheToken() {
        let model = makeModel()
        model.didWrite()
        XCTAssertEqual(model.changeToken, 1)
        model.didWrite()
        model.didWrite()
        XCTAssertEqual(model.changeToken, 3)
    }

    // MARK: - Onboarding and theme persist through the injected store

    func testCompleteOnboardingPersistsToTheInjectedSettingsStore() {
        let model = makeModel()
        model.completeOnboarding()
        XCTAssertTrue(model.onboardingComplete)
        XCTAssertTrue(settings.onboardingComplete)
        XCTAssertTrue(SettingsStore(defaults: defaults).onboardingComplete, "written to the defaults, not just the instance")
    }

    func testSetThemePersists() {
        let model = makeModel()
        let chosen = LFWThemeConfig(typeface: .inter, palette: .deepSea, accentHueShift: -45)
        model.setTheme(chosen)
        XCTAssertEqual(model.theme, chosen)
        XCTAssertEqual(SettingsStore(defaults: defaults).theme, chosen)
    }

    func testSetThemeSanitizesAnUnbundledFace() {
        let model = makeModel()
        model.setTheme(LFWThemeConfig(typeface: .newsreader, palette: .sepia, accentHueShift: 0))
        XCTAssertEqual(model.theme.typeface, .fraunces, "never present a face that would render as a fallback")
        XCTAssertEqual(model.theme.palette, .sepia)
        XCTAssertEqual(settings.theme.typeface, .fraunces)
    }

    // MARK: - Inbox drain (§5.1)

    func testDrainInboxWithAURLItemSetsAURLImportAndOpensAdd() throws {
        let inbox = ShareInbox(directory: inboxDirectory)
        try inbox.append(SharedInboxItem(kind: .url, value: "https://example.com/recipes/lentil-soup"))
        let model = makeModel(inbox: inbox)

        model.drainInbox()

        XCTAssertEqual(model.pendingImport, .url(URL(string: "https://example.com/recipes/lentil-soup")!))
        XCTAssertEqual(model.selectedTab, .add)
        XCTAssertEqual(try inbox.peek(), [], "drained: the file is gone")
    }

    func testDrainInboxWithATextItemSetsATextImportAndOpensAdd() throws {
        let inbox = ShareInbox(directory: inboxDirectory)
        let shared = "2 cups flour\n1 egg"
        try inbox.append(SharedInboxItem(kind: .text, value: shared))
        let model = makeModel(inbox: inbox)

        model.drainInbox()

        XCTAssertEqual(model.pendingImport, .text(shared), "text arrives untouched — the Paste path cleans it")
        XCTAssertEqual(model.selectedTab, .add)
    }

    func testDrainInboxWithAnEmptyInboxLeavesEverythingUntouched() throws {
        let inbox = ShareInbox(directory: inboxDirectory)
        let model = makeModel(inbox: inbox)
        model.selectedTab = .recipes

        model.drainInbox()

        XCTAssertNil(model.pendingImport)
        XCTAssertEqual(model.selectedTab, .recipes, "an empty inbox never yanks the user to Add")
    }

    func testDrainInboxWithoutAnInboxIsANoOp() {
        let model = makeModel(inbox: nil)
        model.selectedTab = .recipes
        model.drainInbox()
        XCTAssertNil(model.pendingImport)
        XCTAssertEqual(model.selectedTab, .recipes)
    }

    func testDrainInboxKeepsLaterItemsForTheNextForeground() throws {
        let inbox = ShareInbox(directory: inboxDirectory)
        try inbox.append(SharedInboxItem(kind: .url, value: "https://example.com/one"))
        try inbox.append(SharedInboxItem(kind: .text, value: "second share"))
        let model = makeModel(inbox: inbox)

        model.drainInbox()

        XCTAssertEqual(model.pendingImport, .url(URL(string: "https://example.com/one")!), "first item wins")
        let remaining = try inbox.peek()
        XCTAssertEqual(remaining.count, 1, "the second share is not silently dropped")
        XCTAssertEqual(remaining.first?.kind, .text)
        XCTAssertEqual(remaining.first?.value, "second share")
    }

    func testURLItemThatDoesNotParseFallsBackToText() {
        // An empty value is the one string `URL(string:)` refuses on every iOS.
        XCTAssertEqual(AppModel.makePendingImport(from: SharedInboxItem(kind: .url, value: "")), .text(""))
        XCTAssertEqual(AppModel.makePendingImport(from: SharedInboxItem(kind: .url, value: "  https://example.com/x  ")),
                       .url(URL(string: "https://example.com/x")!), "surrounding whitespace is trimmed for the URL")
        XCTAssertEqual(AppModel.makePendingImport(from: SharedInboxItem(kind: .text, value: "https://example.com/x")),
                       .text("https://example.com/x"), "a text item stays text even when it looks like a link")
    }

    // MARK: - Pipeline (§7)

    func testMakePipelineSucceedsOverTheSeededRegistry() throws {
        let model = makeModel()
        let pipeline = try model.makePipeline()
        XCTAssertFalse(pipeline.resolver.index.isEmpty)
        XCTAssertEqual(pipeline.resolver.index.entries.count, try store.ingredientCount())
        XCTAssertNotNil(pipeline.resolver.index.exactMatch("Garlic"))
        XCTAssertNil(pipeline.resolver.semantic, "NoopEmbedding is never ready, so layer 3 is off")
    }

    func testMakePipelineResolvesAPastedLineEndToEnd() async throws {
        let model = makeModel()
        let pipeline = try model.makePipeline()
        let outcome = await pipeline.run(text: "3 cloves garlic\n1 onion", source: RecipeSource(kind: .text, titleGuess: "Test"))
        guard case .draft(let parsed) = outcome else {
            return XCTFail("expected a draft, got \(outcome)")
        }
        XCTAssertEqual(parsed.draft.rows.count, 2)
        XCTAssertEqual(parsed.draft.rows[0].ingredientName, "Garlic")
        XCTAssertEqual(parsed.draft.rows[1].ingredientName, "Onion")
    }

    func testMakePipelineBuildsAndCachesTheSemanticSetWhenEmbeddingsAreReady() throws {
        // `FakeEmbedding` lives in SemanticMatchingTests.swift (same test module).
        let embedding = FakeEmbedding(ready: true, vectors: ["Garlic": [1, 0], "Onion": [0, 1]])
        let model = makeModel(embedding: embedding)

        let first = try model.makePipeline()
        let semantic = try XCTUnwrap(first.resolver.semantic, "a ready embedding turns layer 3 on")
        XCTAssertEqual(semantic.candidates.count, 2, "only the names the embedding could vectorize")
        let requestsAfterFirstBuild = embedding.requests.count

        let second = try model.makePipeline()
        XCTAssertEqual(second.resolver.semantic, semantic)
        XCTAssertEqual(embedding.requests.count, requestsAfterFirstBuild, "same entry count → cached, nothing re-embedded")
    }

    func testSemanticSetIsRebuiltWhenASaveAddsACanonical() throws {
        let embedding = FakeEmbedding(ready: true, vectors: ["Garlic": [1, 0], "Za'atar": [0, 1]])
        let model = makeModel(embedding: embedding)
        let before = try XCTUnwrap(try model.makePipeline().resolver.semantic)
        XCTAssertEqual(before.candidates.count, 1)

        // A Confirm "Create" lands a new canonical through the one write path.
        let pending = PendingIngredient(name: "Za'atar", category: .pantry)
        let row = DraftRow(lineIndex: 0, rawLine: "1 tbsp za'atar", name: "za'atar",
                           quantity: 1, unitKey: "tbsp", unitText: "tbsp",
                           ingredient: .pending(pending.id), ingredientName: "Za'atar", resolution: .user)
        let draft = RecipeDraft(title: "Flatbread", source: RecipeSource(kind: .text),
                                rawLines: ["1 tbsp za'atar"], rows: [row], newIngredients: [pending])
        try model.saveRecipe(draft)

        let after = try XCTUnwrap(try model.makePipeline().resolver.semantic)
        XCTAssertEqual(after.candidates.count, 2, "entry count changed → rebuilt with the new canonical")
    }

    func testSemanticSetIsNotCachedWhileEmbeddingsAreNotReady() throws {
        let embedding = FakeEmbedding(ready: false, vectors: ["Garlic": [1, 0]])
        let model = makeModel(embedding: embedding)
        XCTAssertNil(try model.makePipeline().resolver.semantic)

        embedding.ready = true
        XCTAssertNotNil(try model.makePipeline().resolver.semantic, "becoming ready later turns layer 3 on — no frozen-off cache")
    }

    // MARK: - The one save path

    func testSaveRecipeWritesThroughTheStoreAndBumpsTheToken() throws {
        let model = makeModel()
        let id = try model.saveRecipe(try garlicDraft(title: "Test soup"))

        XCTAssertEqual(model.changeToken, 1)
        let saved = try XCTUnwrap(try store.recipe(id: id))
        XCTAssertEqual(saved.title, "Test soup")
        XCTAssertEqual(saved.lineCount, 1)
        XCTAssertFalse(saved.isSelected, "saving never selects; “cooking this” is a separate tap")
        XCTAssertEqual(try store.recipes().count, 1)
    }

    func testARefusedDraftThrowsAndDoesNotBumpTheToken() throws {
        let model = makeModel()
        XCTAssertThrowsError(try model.saveRecipe(try garlicDraft(title: "   "))) { error in
            XCTAssertEqual(error as? RecipeValidationError, .emptyTitle)
        }
        XCTAssertEqual(model.changeToken, 0)
        XCTAssertEqual(try store.recipes().count, 0)
    }
}
