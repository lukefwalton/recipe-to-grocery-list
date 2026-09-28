import XCTest
@testable import RecipeToGroceryList

/// The Confirm screen's decisions (spec §7.5) at the model's altitude: a hand-built
/// `ParsedRecipe` over a three-entry index, one row in each state, and every tap the
/// screen can make. The alias rules — one owner per term, the model never writes one,
/// a walked-back tap teaches nothing — are the point; the two store-backed tests at
/// the end prove the draft the model produces round-trips through the real write
/// path and that the store's own refusal surfaces when the model's snapshot is stale.
///
/// No pipeline, no model, no network: rows are constructed directly so each state is
/// deterministic. Store tests open a temp-file database seeded from the test bundle,
/// as `RecipeStoreTests` does.
@MainActor
final class ConfirmModelTests: XCTestCase {

    private var dbPath: String!
    private var store: RecipeStore?

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "rtg-confirm-\(UUID().uuidString).sqlite"
    }

    override func tearDownWithError() throws {
        store = nil   // close the connection before deleting files
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }

    // MARK: - Fixtures

    private static let brothID: Int64 = 1
    private static let garlicID: Int64 = 2
    private static let onionID: Int64 = 3

    private static func entry(_ id: Int64, _ name: String, _ category: IngredientCategory, _ aliases: [String] = []) -> IngredientIndexEntry {
        IngredientIndexEntry(id: id, canonicalName: name, category: category,
                             aliases: aliases.map(IngredientNormalizer.normalize))
    }

    private let index = IngredientIndex(entries: [
        ConfirmModelTests.entry(ConfirmModelTests.brothID, "Vegetable broth", .pantry, ["veggie broth"]),
        ConfirmModelTests.entry(ConfirmModelTests.garlicID, "Garlic", .produce),
        ConfirmModelTests.entry(ConfirmModelTests.onionID, "Onion", .produce),
    ])

    private static func suggestion(_ id: Int64, _ name: String) -> IngredientSuggestion {
        IngredientSuggestion(ingredientID: id, canonicalName: name, score: 1, via: .llm)
    }

    /// One row per §7.5 state (text and removed are reached by tapping). Line 0 is a
    /// section header, so `lineIndex` starts at 1.
    private struct Fixture {
        let resolved: DraftRow
        let highlighted: DraftRow
        let suggested: DraftRow
        let new: DraftRow
        var rows: [DraftRow] { [resolved, highlighted, suggested, new] }
        var rawLines: [String] { ["For the soup:"] + rows.map(\.rawLine) }
    }

    private static func fixture() -> Fixture {
        Fixture(
            resolved: DraftRow(lineIndex: 1, rawLine: "3 cloves garlic", name: "garlic",
                               quantity: 3, unitKey: "clove", unitText: "cloves",
                               ingredient: .existing(garlicID), ingredientName: "Garlic", resolution: .exact),
            highlighted: DraftRow(lineIndex: 2, rawLine: "1 large onion", name: "onion",
                                  quantity: 1, note: "large",
                                  ingredient: .existing(onionID), ingredientName: "Onion", resolution: .fuzzy),
            suggested: DraftRow(lineIndex: 3, rawLine: "2 cups veggie stock", name: "veggie stock",
                                quantity: 2, unitKey: "cup", unitText: "cups",
                                suggestion: suggestion(brothID, "Vegetable broth")),
            new: DraftRow(lineIndex: 4, rawLine: "1 tbsp harissa paste", name: "harissa paste",
                          quantity: 1, unitKey: "tbsp", unitText: "tbsp", confidence: .low)
        )
    }

    private func makeModel(rows: [DraftRow],
                           rawLines: [String]? = nil,
                           title: String = "Lentil soup",
                           newIngredients: [PendingIngredient] = [],
                           newAliases: [PendingAlias] = [],
                           index: IngredientIndex? = nil) -> ConfirmModel {
        let draft = RecipeDraft(title: title,
                                source: RecipeSource(kind: .text),
                                rawLines: rawLines ?? rows.map(\.rawLine),
                                rows: rows,
                                newIngredients: newIngredients,
                                newAliases: newAliases)
        return ConfirmModel(parsed: ParsedRecipe(draft: draft, usedOnDeviceAI: false, warning: nil),
                            index: index ?? self.index)
    }

    private func makeModel(_ fixture: Fixture) -> ConfirmModel {
        makeModel(rows: fixture.rows, rawLines: fixture.rawLines)
    }

    private func row(_ id: UUID, in model: ConfirmModel, file: StaticString = #filePath, line: UInt = #line) throws -> DraftRow {
        try XCTUnwrap(model.draft.row(id: id), "row \(id) is in the draft", file: file, line: line)
    }

    // MARK: - Initial state

    func testInitCarriesTheParseFactsAndDerivesTheGate() throws {
        let fixture = Self.fixture()
        let parsedDraft = RecipeDraft(title: "Lentil soup", source: RecipeSource(kind: .text),
                                      rawLines: fixture.rawLines, rows: fixture.rows)
        let model = ConfirmModel(parsed: ParsedRecipe(draft: parsedDraft, usedOnDeviceAI: true, warning: "One line looked odd."),
                                 index: index)

        XCTAssertEqual(model.draft, parsedDraft)
        XCTAssertTrue(model.usedOnDeviceAI)
        XCTAssertEqual(model.warning, "One line looked odd.")
        XCTAssertEqual(model.index, index)
        XCTAssertEqual(fixture.rows.map(\.state), [.resolved, .highlighted, .suggested, .new])
        XCTAssertFalse(model.canSave, "a suggested and a new row still need a tap")
        XCTAssertEqual(model.rowsNeedingDecision, 2)
        XCTAssertEqual(model.draft.headerLineIndices, [0])
    }

    func testDisplayNameLooksUpLiveAndFallsBackToTheNameAsWritten() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)
        XCTAssertEqual(model.displayName(for: fixture.resolved), "Garlic")
        XCTAssertEqual(model.displayName(for: fixture.suggested), "veggie stock", "no ingredient yet → the name as written")
        model.createIngredient(fixture.new.id, category: .pantry)
        XCTAssertEqual(model.displayName(for: try row(fixture.new.id, in: model)), "harissa paste", "a pending ingredient's name")
    }

    func testAlternativesPutTheSuggestionFirstAndSkipTheCurrentMatch() throws {
        var highlighted = Self.fixture().highlighted
        highlighted.alternatives = [
            IngredientSuggestion(ingredientID: Self.onionID, canonicalName: "Onion", score: 0.9, via: .fuzzy),   // the current match
            IngredientSuggestion(ingredientID: Self.garlicID, canonicalName: "Garlic", score: 0.8, via: .fuzzy),
            IngredientSuggestion(ingredientID: 999, canonicalName: "Gone", score: 0.8, via: .fuzzy),             // not in the index
        ]
        var suggested = Self.fixture().suggested
        suggested.alternatives = [
            IngredientSuggestion(ingredientID: Self.brothID, canonicalName: "Vegetable broth", score: 0.8, via: .fuzzy),  // duplicate of the suggestion
            IngredientSuggestion(ingredientID: Self.onionID, canonicalName: "Onion", score: 0.79, via: .embedding),
        ]
        let model = makeModel(rows: [highlighted, suggested])

        XCTAssertEqual(model.alternatives(for: highlighted.id).map(\.ingredientID), [Self.garlicID])
        XCTAssertEqual(model.alternatives(for: suggested.id).map(\.ingredientID), [Self.brothID, Self.onionID])
        XCTAssertEqual(model.alternatives(for: suggested.id).first?.via, .llm, "the model's guess leads")
        XCTAssertEqual(model.alternatives(for: UUID()), [])
    }

    // MARK: - Use (§7.5 "Suggested")

    func testUseSuggestionResolvesTheRowAsUserAndQueuesTheAlias() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)

        try model.useSuggestion(fixture.suggested.id)

        let decided = try row(fixture.suggested.id, in: model)
        XCTAssertEqual(decided.ingredient, .existing(Self.brothID))
        XCTAssertEqual(decided.ingredientName, "Vegetable broth")
        XCTAssertEqual(decided.resolution, .user, "every user choice is recorded as .user")
        XCTAssertNil(decided.suggestion)
        XCTAssertFalse(decided.keepAsText)
        XCTAssertEqual(decided.state, .resolved)
        XCTAssertEqual(decided.name, "veggie stock", "the name as written is untouched")
        XCTAssertEqual(model.draft.newAliases, [PendingAlias(alias: "veggie stock", target: .existing(Self.brothID))],
                       "Use is how the alias table grows — name → X, written by the tap, not the model")
        XCTAssertEqual(model.rowsNeedingDecision, 1)
    }

    func testUseSuggestionQueuesNoAliasWhenTheNameAlreadyMeansTheTarget() throws {
        let alreadyAlias = DraftRow(lineIndex: 0, rawLine: "2 cups Veggie Broth", name: "Veggie Broth",
                                    suggestion: Self.suggestion(Self.brothID, "Vegetable broth"))
        let alreadyCanonical = DraftRow(lineIndex: 1, rawLine: "1 garlic", name: "garlic",
                                        suggestion: Self.suggestion(Self.garlicID, "Garlic"))
        let model = makeModel(rows: [alreadyAlias, alreadyCanonical])

        try model.useSuggestion(alreadyAlias.id)
        try model.useSuggestion(alreadyCanonical.id)

        XCTAssertEqual(try row(alreadyAlias.id, in: model).ingredient, .existing(Self.brothID))
        XCTAssertEqual(try row(alreadyCanonical.id, in: model).ingredient, .existing(Self.garlicID))
        XCTAssertTrue(model.draft.newAliases.isEmpty, "nothing to teach: the registry already resolves both names")
    }

    func testUseSuggestionRefusesAnAliasOwnedByAnotherCanonical() throws {
        // The model guessed Garlic for a line whose name already means Vegetable broth.
        let contested = DraftRow(lineIndex: 0, rawLine: "2 cups veggie broth", name: "veggie broth",
                                 suggestion: Self.suggestion(Self.garlicID, "Garlic"))
        let model = makeModel(rows: [contested])

        XCTAssertThrowsError(try model.useSuggestion(contested.id)) { error in
            XCTAssertEqual(error as? AliasRefusal, AliasRefusal(alias: "veggie broth", ownerName: "Vegetable broth"))
            XCTAssertEqual((error as? AliasRefusal)?.message, "“veggie broth” already means Vegetable broth")
        }
        let untouched = try row(contested.id, in: model)
        XCTAssertNil(untouched.ingredient, "a refused tap changes nothing")
        XCTAssertNotNil(untouched.suggestion)
        XCTAssertEqual(untouched.state, .suggested)
        XCTAssertTrue(model.draft.newAliases.isEmpty)
        XCTAssertFalse(model.canSave)
    }

    func testAliasOwnerConflictNamesTheOwnerInEveryPlaceAnOwnerCanLive() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)

        // The registry's alias table.
        XCTAssertEqual(model.aliasOwnerConflict(alias: "Veggie Broth", target: .existing(Self.garlicID)),
                       AliasRefusal(alias: "Veggie Broth", ownerName: "Vegetable broth"))
        XCTAssertNil(model.aliasOwnerConflict(alias: "Veggie Broth", target: .existing(Self.brothID)), "same owner is not a conflict")
        // A canonical name is its own alias (layer 0 would win before any new alias).
        XCTAssertEqual(model.aliasOwnerConflict(alias: "onion", target: .existing(Self.garlicID)),
                       AliasRefusal(alias: "onion", ownerName: "Onion"))
        // An in-draft alias from an earlier tap.
        try model.useSuggestion(fixture.suggested.id)   // "veggie stock" → Vegetable broth
        XCTAssertEqual(model.aliasOwnerConflict(alias: "veggie stock", target: .existing(Self.onionID)),
                       AliasRefusal(alias: "veggie stock", ownerName: "Vegetable broth"))
        // A pending ingredient created this session.
        model.createIngredient(fixture.new.id, category: .pantry)
        XCTAssertEqual(model.aliasOwnerConflict(alias: "Harissa Paste", target: .existing(Self.onionID)),
                       AliasRefusal(alias: "Harissa Paste", ownerName: "harissa paste"))
        // Free terms and blanks are fine.
        XCTAssertNil(model.aliasOwnerConflict(alias: "moon dust", target: .existing(Self.onionID)))
        XCTAssertNil(model.aliasOwnerConflict(alias: "   ", target: .existing(Self.onionID)))
    }

    // MARK: - Same as… / change (§7.5 "New" and "Resolved")

    func testSameAsQueuesAnAliasAndAPlainChangeDoesNot() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)

        try model.choose(fixture.new.id, ingredientID: Self.onionID, addAlias: true)
        var decided = try row(fixture.new.id, in: model)
        XCTAssertEqual(decided.ingredient, .existing(Self.onionID))
        XCTAssertEqual(decided.ingredientName, "Onion")
        XCTAssertEqual(decided.resolution, .user)
        XCTAssertEqual(model.draft.newAliases, [PendingAlias(alias: "harissa paste", target: .existing(Self.onionID))])

        // Changing a resolved row's ingredient teaches nothing…
        try model.choose(fixture.resolved.id, ingredientID: Self.brothID, addAlias: false)
        decided = try row(fixture.resolved.id, in: model)
        XCTAssertEqual(decided.ingredient, .existing(Self.brothID))
        XCTAssertEqual(decided.resolution, .user, "even a plain change is the user's call now")
        XCTAssertEqual(model.draft.newAliases.count, 1)

        // …and an unknown id is ignored rather than producing a dangling reference.
        try model.choose(fixture.highlighted.id, ingredientID: 999, addAlias: true)
        XCTAssertEqual(try row(fixture.highlighted.id, in: model), fixture.highlighted)
    }

    func testSameAsAnIngredientCreatedInThisRecipeQueuesAnAliasToThePendingTarget() throws {
        let paste = DraftRow(lineIndex: 0, rawLine: "1 tbsp harissa paste", name: "harissa paste")
        let rose = DraftRow(lineIndex: 1, rawLine: "2 tsp rose harissa", name: "rose harissa")
        let same = DraftRow(lineIndex: 2, rawLine: "Harissa Paste, to taste", name: "Harissa Paste", note: "to taste")
        let clash = DraftRow(lineIndex: 3, rawLine: "1 clove garlic", name: "garlic")
        let model = makeModel(rows: [paste, rose, same, clash])

        model.createIngredient(paste.id, category: .pantry)
        let pending = try XCTUnwrap(model.draft.newIngredients.first)

        // Same as… → the new canonical teaches "rose harissa" for next time (§7.5).
        try model.choosePending(rose.id, pendingID: pending.id, addAlias: true)
        let decided = try row(rose.id, in: model)
        XCTAssertEqual(decided.ingredient, .pending(pending.id))
        XCTAssertEqual(decided.ingredientName, "harissa paste")
        XCTAssertEqual(decided.resolution, .user)
        XCTAssertEqual(decided.state, .resolved)
        XCTAssertEqual(model.draft.newAliases, [PendingAlias(alias: "rose harissa", target: .pending(pending.id))])

        // A name that already normalizes to the pending name has nothing to learn.
        try model.choosePending(same.id, pendingID: pending.id, addAlias: true)
        XCTAssertEqual(try row(same.id, in: model).ingredient, .pending(pending.id))
        XCTAssertEqual(model.draft.newAliases.count, 1)

        // A term the registry already owns is refused, naming the owner.
        XCTAssertThrowsError(try model.choosePending(clash.id, pendingID: pending.id, addAlias: true)) { error in
            XCTAssertEqual(error as? AliasRefusal, AliasRefusal(alias: "garlic", ownerName: "Garlic"))
        }
        XCTAssertNil(try row(clash.id, in: model).ingredient, "a refused tap changes nothing")

        // A plain change of ingredient teaches nothing, and drops the alias the row sponsored.
        try model.choose(rose.id, ingredientID: Self.onionID, addAlias: false)
        try model.choosePending(rose.id, pendingID: pending.id, addAlias: false)
        XCTAssertTrue(model.draft.newAliases.isEmpty)
        model.keepAsText(clash.id)
        XCTAssertTrue(model.canSave)
    }

    func testChangingYourMindReplacesYourOwnAliasButNotAnotherRowsAlias() throws {
        let first = DraftRow(lineIndex: 0, rawLine: "1 cup stock", name: "stock")
        let second = DraftRow(lineIndex: 1, rawLine: "2 cups stock", name: "stock")
        let model = makeModel(rows: [first, second])

        try model.choose(first.id, ingredientID: Self.garlicID, addAlias: true)
        // The second row wants the same term to mean something else: refused, naming the in-draft owner.
        XCTAssertThrowsError(try model.choose(second.id, ingredientID: Self.onionID, addAlias: true)) { error in
            XCTAssertEqual(error as? AliasRefusal, AliasRefusal(alias: "stock", ownerName: "Garlic"))
        }
        // The same target is fine and does not queue a duplicate alias.
        try model.choose(second.id, ingredientID: Self.garlicID, addAlias: true)
        XCTAssertEqual(model.draft.newAliases, [PendingAlias(alias: "stock", target: .existing(Self.garlicID))])

        // The first row cannot re-point "stock" while the second row still sponsors the alias…
        XCTAssertThrowsError(try model.choose(first.id, ingredientID: Self.onionID, addAlias: true))
        // …but once the second row is kept as text, changing the first row's mind replaces its own alias.
        model.keepAsText(second.id)
        XCTAssertEqual(model.draft.newAliases.count, 1, "the alias survives while the first row still sponsors it")
        try model.choose(first.id, ingredientID: Self.onionID, addAlias: true)
        XCTAssertEqual(model.draft.newAliases, [PendingAlias(alias: "stock", target: .existing(Self.onionID))],
                       "a walked-back tap teaches nothing; the new tap teaches the new mapping")
    }

    // MARK: - Create (§7.5 "New")

    func testCreateIngredientDedupesByNormalizedNameAndRecordsUser() throws {
        let paste = DraftRow(lineIndex: 0, rawLine: "1 tbsp harissa paste", name: "harissa paste")
        let pastes = DraftRow(lineIndex: 1, rawLine: "Harissa Pastes, to taste", name: "Harissa Pastes", note: "to taste")
        let model = makeModel(rows: [paste, pastes])

        model.createIngredient(paste.id, category: .pantry)
        model.createIngredient(pastes.id, category: .other)   // a different category does not split the ingredient

        XCTAssertEqual(model.draft.newIngredients.count, 1, "two spellings of one name are one new canonical")
        let pending = try XCTUnwrap(model.draft.newIngredients.first)
        XCTAssertEqual(pending.name, "harissa paste", "named after the first row, as written")
        XCTAssertEqual(pending.category, .pantry, "the first Create's category sticks")
        for id in [paste.id, pastes.id] {
            let decided = try row(id, in: model)
            XCTAssertEqual(decided.ingredient, .pending(pending.id))
            XCTAssertEqual(decided.ingredientName, "harissa paste")
            XCTAssertEqual(decided.resolution, .user)
            XCTAssertEqual(decided.state, .resolved)
        }
        XCTAssertTrue(model.draft.newAliases.isEmpty, "Create writes a canonical, not an alias")
        XCTAssertTrue(model.canSave)
        XCTAssertNoThrow(try RecipeValidator.validate(model.draft), "the validator accepts what Create produced")
    }

    func testCreateIngredientPointsAtAnExistingCanonicalInsteadOfDuplicatingIt() throws {
        // Only reachable after an edit: the resolver would have matched "Garlic" already.
        let renamed = DraftRow(lineIndex: 0, rawLine: "2 cloves garlick", name: "garlick")
        let model = makeModel(rows: [renamed])
        model.setName(renamed.id, "Garlic")
        model.createIngredient(renamed.id, category: .produce)

        XCTAssertTrue(model.draft.newIngredients.isEmpty, "no second Garlic")
        let decided = try row(renamed.id, in: model)
        XCTAssertEqual(decided.ingredient, .existing(Self.garlicID))
        XCTAssertEqual(decided.resolution, .user)
    }

    func testCreateIngredientIgnoresABlankName() throws {
        let blank = DraftRow(lineIndex: 0, rawLine: "(optional)", name: "(optional)")
        let model = makeModel(rows: [blank])
        model.createIngredient(blank.id, category: .other)
        XCTAssertTrue(model.draft.newIngredients.isEmpty, "a name that normalizes to nothing can never resolve again")
        XCTAssertEqual(try row(blank.id, in: model).state, .new, "the Save gate keeps pointing at the row")
    }

    // MARK: - Keep as text, remove, restore

    func testKeepAsTextLeavesNoIngredientAndNoResolution() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)
        try model.useSuggestion(fixture.suggested.id)   // resolved with an alias queued…

        model.keepAsText(fixture.suggested.id)          // …then the user walks it back to text
        model.keepAsText(fixture.new.id)

        for id in [fixture.suggested.id, fixture.new.id] {
            let text = try row(id, in: model)
            XCTAssertNil(text.ingredient)
            XCTAssertNil(text.ingredientName)
            XCTAssertEqual(text.resolution, .none, "kept as text ⇒ resolution none (the validator's rule)")
            XCTAssertTrue(text.keepAsText)
            XCTAssertFalse(text.isRemoved)
            XCTAssertEqual(text.state, .text)
        }
        XCTAssertTrue(model.draft.newAliases.isEmpty, "the alias from the walked-back Use is gone")
        XCTAssertTrue(model.canSave)
        XCTAssertNoThrow(try RecipeValidator.validate(model.draft))
    }

    func testRemoveAndRestoreToggleWithoutLosingTheDecision() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)

        model.remove(fixture.resolved.id)
        var removed = try row(fixture.resolved.id, in: model)
        XCTAssertTrue(removed.isRemoved)
        XCTAssertEqual(removed.state, .removed)
        XCTAssertFalse(removed.blocksSave, "a removed line never blocks Save")
        XCTAssertEqual(model.draft.keptRows.count, 3)
        XCTAssertEqual(model.draft.rawLines.count, 5, "every raw line survives (§1)")

        model.restore(fixture.resolved.id)
        removed = try row(fixture.resolved.id, in: model)
        XCTAssertFalse(removed.isRemoved)
        XCTAssertEqual(removed.state, .resolved)
        XCTAssertEqual(removed.ingredient, .existing(Self.garlicID), "an existing ingredient survives the round trip")
        XCTAssertEqual(removed.resolution, .exact)

        // Removing the only kept rows disables Save (a recipe needs at least one row).
        for r in fixture.rows { model.remove(r.id) }
        XCTAssertTrue(model.draft.keptRows.isEmpty)
        XCTAssertEqual(model.rowsNeedingDecision, 0)
        XCTAssertFalse(model.canSave)
    }

    func testRemovingTheLastReferencePrunesThePendingIngredientAndItsAliases() throws {
        let pending = PendingIngredient(name: "Ube jam", category: .pantry)
        let jam = DraftRow(lineIndex: 0, rawLine: "1 tbsp ube jam", name: "ube jam",
                           ingredient: .pending(pending.id), ingredientName: "Ube jam", resolution: .user)
        let garlic = Self.fixture().resolved
        let model = makeModel(rows: [jam, garlic],
                              newIngredients: [pending],
                              newAliases: [PendingAlias(alias: "ube jam", target: .pending(pending.id)),
                                           PendingAlias(alias: "garlick", target: .existing(Self.garlicID))])

        model.remove(jam.id)

        XCTAssertTrue(model.draft.newIngredients.isEmpty, "no kept row references it → dropped")
        XCTAssertEqual(model.draft.newAliases, [PendingAlias(alias: "garlick", target: .existing(Self.garlicID))],
                       "the alias that targeted the pruned ingredient goes with it; unrelated aliases stay")

        model.restore(jam.id)
        let restored = try row(jam.id, in: model)
        XCTAssertFalse(restored.isRemoved)
        XCTAssertNil(restored.ingredient, "its new ingredient is gone, so the row comes back undecided rather than dangling")
        XCTAssertEqual(restored.resolution, .none)
        XCTAssertEqual(restored.state, .new)
    }

    func testPendingIngredientSurvivesWhileAnotherRowStillReferencesIt() throws {
        let paste = DraftRow(lineIndex: 0, rawLine: "1 tbsp harissa paste", name: "harissa paste")
        let more = DraftRow(lineIndex: 1, rawLine: "harissa paste, for serving", name: "harissa paste", note: "for serving")
        let model = makeModel(rows: [paste, more])
        model.createIngredient(paste.id, category: .pantry)
        model.createIngredient(more.id, category: .pantry)
        XCTAssertEqual(model.draft.newIngredients.count, 1)

        model.keepAsText(paste.id)
        XCTAssertEqual(model.draft.newIngredients.count, 1, "the second row still needs it")
        model.remove(more.id)
        XCTAssertTrue(model.draft.newIngredients.isEmpty, "now nobody does")
    }

    // MARK: - Field edits

    func testSetNameResolvesNothingButClearsAStaleSuggestionAndItsAlias() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)

        model.setName(fixture.suggested.id, "  chicken stock ")
        var edited = try row(fixture.suggested.id, in: model)
        XCTAssertEqual(edited.name, "chicken stock", "trimmed")
        XCTAssertNil(edited.suggestion, "the model's guess was about the old name")
        XCTAssertNil(edited.ingredient, "nothing is re-resolved behind the user's back")
        XCTAssertEqual(edited.state, .new)

        // A queued alias is a promise about the name as it was tapped: renaming drops it, the mapping stays.
        try model.choose(fixture.new.id, ingredientID: Self.brothID, addAlias: true)
        XCTAssertEqual(model.draft.newAliases.count, 1)
        model.setName(fixture.new.id, "Harissa Paste")   // same normalized name → the alias is still valid
        XCTAssertEqual(model.draft.newAliases.count, 1)
        model.setName(fixture.new.id, "rose harissa")
        edited = try row(fixture.new.id, in: model)
        XCTAssertTrue(model.draft.newAliases.isEmpty)
        XCTAssertEqual(edited.ingredient, .existing(Self.brothID), "the row keeps its ingredient")
        XCTAssertEqual(edited.resolution, .user)

        // Blank and unchanged names are ignored.
        model.setName(fixture.resolved.id, "   ")
        XCTAssertEqual(try row(fixture.resolved.id, in: model).name, "garlic")
    }

    func testQuantityUnitAndNoteEditsStickAndBadValuesAreRefused() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)
        let id = fixture.resolved.id

        model.setQuantity(id, 1.5)
        model.setUnit(id, unitKey: "tbsp", unitText: nil)
        model.setNote(id, "  divided ")
        var edited = try row(id, in: model)
        XCTAssertEqual(edited.quantity, 1.5)
        XCTAssertEqual(edited.unitKey, "tbsp")
        XCTAssertNil(edited.unitText)
        XCTAssertEqual(edited.note, "divided")

        model.setUnit(id, unitKey: nil, unitText: "  heaping spoonfuls ")
        edited = try row(id, in: model)
        XCTAssertNil(edited.unitKey)
        XCTAssertEqual(edited.unitText, "heaping spoonfuls", "no key → the spelling is kept for display")

        model.setUnit(id, unitKey: "furlong", unitText: nil)   // not in UnitTable
        model.setQuantity(id, -1)
        model.setQuantity(id, .infinity)
        edited = try row(id, in: model)
        XCTAssertNil(edited.unitKey, "an unknown key is ignored")
        XCTAssertEqual(edited.quantity, 1.5, "the validator's quantity rule is applied at edit time")

        model.setQuantity(id, nil)
        model.setNote(id, "   ")
        edited = try row(id, in: model)
        XCTAssertNil(edited.quantity)
        XCTAssertNil(edited.note, "blank collapses to nil")

        // Decide the rows that still need a tap; the edits above must leave the rest valid.
        try model.useSuggestion(fixture.suggested.id)
        model.keepAsText(fixture.new.id)
        XCTAssertNoThrow(try RecipeValidator.validate(model.draft))
    }

    // MARK: - The Save gate (§7.5)

    func testCanSaveIsFalseWhileAnyRowIsNewOrSuggestedAndTrueOnceAllAreDecided() throws {
        let fixture = Self.fixture()
        let model = makeModel(fixture)
        XCTAssertFalse(model.canSave)
        XCTAssertEqual(model.rowsNeedingDecision, 2)

        try model.useSuggestion(fixture.suggested.id)
        XCTAssertFalse(model.canSave, "one New row still blocks")
        XCTAssertEqual(model.rowsNeedingDecision, 1)

        model.createIngredient(fixture.new.id, category: .pantry)
        XCTAssertTrue(model.canSave)
        XCTAssertEqual(model.rowsNeedingDecision, 0)

        model.draft.title = "   "
        XCTAssertFalse(model.canSave, "a title is part of the gate")
        model.draft.title = "Lentil soup"
        XCTAssertTrue(model.canSave)
        XCTAssertNoThrow(try RecipeValidator.validate(model.draft), "what the gate accepts, the validator accepts")
    }

    // MARK: - Through the real store

    private func makeSeededStore() throws -> (store: RecipeStore, index: IngredientIndex) {
        let store = RecipeStore(db: try SQLiteDB(path: dbPath))
        try store.migrate()
        try store.seedIngredientsIfNeeded(IngredientSeed.load(from: Bundle(for: Self.self)))
        self.store = store
        return (store, try store.ingredientIndex())
    }

    func testSaveRoundTripsThroughARealStore() throws {
        let (store, index) = try makeSeededStore()
        let garlic = try XCTUnwrap(index.exactMatch("Garlic"))
        let broth = try XCTUnwrap(index.exactMatch("Vegetable broth"))
        XCTAssertNil(index.aliasOwner(normalizedAlias: "veg stock"), "the seed does not know this spelling yet")
        XCTAssertNil(index.exactMatch("ube jam"))

        let rows = [
            DraftRow(lineIndex: 1, rawLine: "3 cloves garlic, minced", name: "garlic",
                     quantity: 3, unitKey: "clove", unitText: "cloves", note: "minced",
                     ingredient: .existing(garlic), ingredientName: "Garlic", resolution: .exact),
            DraftRow(lineIndex: 2, rawLine: "2 cups veg stock", name: "veg stock",
                     quantity: 2, unitKey: "cup", unitText: "cups",
                     suggestion: Self.suggestion(broth, "Vegetable broth")),
            DraftRow(lineIndex: 3, rawLine: "1 tbsp ube jam", name: "ube jam",
                     quantity: 1, unitKey: "tbsp", unitText: "tbsp"),
            DraftRow(lineIndex: 4, rawLine: "a splash of something", name: "a splash of something"),
            DraftRow(lineIndex: 5, rawLine: "Serves 4", name: "serves 4", quantity: 4),
        ]
        let rawLines = ["For the soup:"] + rows.map(\.rawLine)
        let draft = RecipeDraft(title: "  Lentil soup ",
                                source: RecipeSource(kind: .url, ref: "https://example.com/soup", servingsText: "Serves 4"),
                                rawLines: rawLines,
                                rows: rows)
        let model = ConfirmModel(parsed: ParsedRecipe(draft: draft, usedOnDeviceAI: false), index: index)
        XCTAssertFalse(model.canSave)

        try model.useSuggestion(rows[1].id)                       // Use → alias "veg stock" → Vegetable broth
        model.createIngredient(rows[2].id, category: .pantry)     // Create → custom "ube jam"
        model.keepAsText(rows[3].id)                              // Keep as text
        model.remove(rows[4].id)                                  // Not an ingredient
        XCTAssertTrue(model.canSave)

        let recipeID = try model.save(into: store)

        let recipe = try XCTUnwrap(store.recipe(id: recipeID))
        XCTAssertEqual(recipe.title, "Lentil soup")
        XCTAssertEqual(recipe.rawLines, rawLines, "header and removed line included")
        XCTAssertEqual(recipe.sourceKind, .url)
        XCTAssertEqual(recipe.sourceRef, "https://example.com/soup")
        XCTAssertEqual(recipe.servingsText, "Serves 4")
        XCTAssertEqual(recipe.lineCount, 4, "the removed line is not a row")
        XCTAssertFalse(recipe.isSelected)

        let stored = try store.recipeIngredients(recipeID: recipeID)
        XCTAssertEqual(stored.map(\.rawLine), ["3 cloves garlic, minced", "2 cups veg stock", "1 tbsp ube jam", "a splash of something"])
        XCTAssertEqual(stored.map(\.sortOrder), [0, 1, 2, 3])
        XCTAssertEqual(stored.map(\.resolution), [.exact, .user, .user, .none])

        XCTAssertEqual(stored[0].ingredientID, garlic)
        XCTAssertEqual(stored[0].quantity, 3)
        XCTAssertEqual(stored[0].unitKey, "clove")
        XCTAssertEqual(stored[0].note, "minced")

        XCTAssertEqual(stored[1].ingredientID, broth)
        XCTAssertEqual(stored[1].name, "veg stock", "the name as written is stored; the canonical is the link")
        XCTAssertEqual(try store.aliasOwner("veg stock"), broth, "the Use tap taught the registry")
        XCTAssertEqual(try store.aliasOwner("Veg Stocks"), broth, "stored normalized")

        let ube = try XCTUnwrap(store.ingredientID(slug: "ube_jam"))
        XCTAssertEqual(stored[2].ingredientID, ube)
        let created = try XCTUnwrap(store.ingredient(id: ube))
        XCTAssertTrue(created.isCustom)
        XCTAssertEqual(created.canonicalName, "ube jam")
        XCTAssertEqual(created.category, .pantry)

        XCTAssertNil(stored[3].ingredientID, "kept as text → NULL ingredient")
        XCTAssertEqual(stored[3].name, "a splash of something")

        // The next parse sees what this save taught.
        let refreshed = try store.ingredientIndex()
        XCTAssertEqual(refreshed.aliasMatch("veg stock"), broth)
        XCTAssertEqual(refreshed.exactMatch("ube jam"), ube)
    }

    func testStoreAliasRefusalSurfacesFromSaveAndLeavesNoRecipe() throws {
        let (store, fullIndex) = try makeSeededStore()
        let garlic = try XCTUnwrap(fullIndex.exactMatch("Garlic"))
        let broth = try XCTUnwrap(fullIndex.exactMatch("Vegetable broth"))

        // A snapshot that never heard of Vegetable broth: the model cannot see the
        // conflict, so the store — the alias table's PRIMARY KEY — must be the one to refuse.
        let staleIndex = IngredientIndex(entries: [IngredientIndexEntry(id: garlic, canonicalName: "Garlic", category: .produce)])
        let contested = DraftRow(lineIndex: 0, rawLine: "2 cups veggie broth", name: "veggie broth", quantity: 2, unitKey: "cup")
        let model = makeModel(rows: [contested], title: "Soup", index: staleIndex)

        try model.choose(contested.id, ingredientID: garlic, addAlias: true)
        XCTAssertEqual(model.draft.newAliases, [PendingAlias(alias: "veggie broth", target: .existing(garlic))])
        XCTAssertTrue(model.canSave, "the model believes the draft is fine")

        XCTAssertThrowsError(try model.save(into: store)) { error in
            XCTAssertEqual(error as? RecipeStoreError,
                           .aliasOwnedElsewhere(alias: "veggie broth", ownerName: "Vegetable broth"))
            XCTAssertEqual((error as? RecipeStoreError)?.description, "\"veggie broth\" already means Vegetable broth")
        }
        XCTAssertEqual(try store.recipes(), [], "the whole save rolled back")
        XCTAssertEqual(try store.count(inTable: "recipe_ingredients"), 0)
        XCTAssertEqual(try store.aliasOwner("veggie broth"), broth, "the existing owner is untouched")
        XCTAssertEqual(model.draft.rows.count, 1, "the draft is still there for the user to fix")
    }
}
