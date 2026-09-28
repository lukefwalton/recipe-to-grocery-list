import Foundation
// `ObservableObject` and `@Published` live in Combine, not Foundation; SwiftUI
// re-exports it, but this model owns no view types and should not import the view
// layer to get a protocol.
import Combine

/// A refused *Same as…* / *Use* tap (spec §7.5): the row's name, normalized the one
/// way (§7.1), already means another canonical — in the registry, as a canonical
/// name, or earlier in this same Confirm session. The tap is refused and the user
/// picks explicitly; nothing in the app ever overrides an alias owner. This is the
/// same rule the store's alias writer enforces at write time
/// (`RecipeStoreError.aliasOwnedElsewhere`), applied here first so the refusal is a
/// tap that fails, not a save that fails.
struct AliasRefusal: Error, Equatable {
    let alias: String
    let ownerName: String

    var message: String { "“\(alias)” already means \(ownerName)" }
}

/// The Confirm screen's state (spec §7.5): one `RecipeDraft` the user edits row by
/// row, plus the registry snapshot the taps are checked against. Every method is a
/// *decision* about a row and nothing here writes — `save(into:)` hands the finished
/// draft to `RecipeStore.save`, the one write path (§1). Model proposes (the draft
/// arrived with the pipeline's proposals), app confirms (these methods), app writes
/// (the store).
///
/// Shape follows the pending-draft editing in `WorkoutChatLog/Features/TodayModel.swift`
/// at `workout-logger@5bffddfb80fc` (`applySuggestion`, `setExerciseName`, `canSave`:
/// the draft is a value, every edit is a method, the view binds to `draft`), with the
/// recipe-specific twist that new canonicals and aliases are *queued on the draft*
/// (`newIngredients`, `newAliases`) and only get ids inside the store's transaction.
///
/// Invariants kept by every decision:
/// - a decided row has `resolution == .user` and no `suggestion`;
/// - a queued alias is sponsored by at least one kept row whose name (normalized)
///   is the alias and whose ingredient is the alias's target — change the row and
///   the alias goes with it, so a save never teaches a mapping the user walked back;
/// - a pending ingredient survives only while a kept row references it (`prune`).
@MainActor
final class ConfirmModel: ObservableObject {
    @Published var draft: RecipeDraft
    let index: IngredientIndex
    let usedOnDeviceAI: Bool
    let warning: String?

    init(parsed: ParsedRecipe, index: IngredientIndex) {
        self.draft = parsed.draft
        self.index = index
        self.usedOnDeviceAI = parsed.usedOnDeviceAI
        self.warning = parsed.warning
    }

    // MARK: - Derived

    /// The Save gate (§7.5) — a title, a kept row, and no row waiting on a tap.
    var canSave: Bool { draft.canSave }

    /// Rows still in *New* or *Suggested*: the Save button's "Resolve N rows" count.
    var rowsNeedingDecision: Int { draft.rows.filter { $0.blocksSave }.count }

    /// What a row's ingredient is called right now. Looked up live rather than
    /// trusting `ingredientName`, so a row can never show a stale label; falls back
    /// to the name as written when the row has no ingredient.
    func displayName(for row: DraftRow) -> String {
        switch row.ingredient {
        case .existing(let id)?:
            return index.entry(id: id)?.canonicalName ?? row.ingredientName ?? row.name
        case .pending(let id)?:
            return draft.pendingIngredient(id: id)?.name ?? row.ingredientName ?? row.name
        case nil:
            return row.name
        }
    }

    /// The near misses the picker shows first as "Close matches": the layer-4
    /// suggestion (if any) ahead of the fuzzy / embedding alternatives, deduplicated,
    /// minus whatever the row already points at, minus anything the index no longer
    /// knows (a stale suggestion must never become a dangling `.existing`).
    func alternatives(for rowID: UUID) -> [IngredientSuggestion] {
        guard let row = draft.row(id: rowID) else { return [] }
        var current: Int64? = nil
        if case .existing(let id)? = row.ingredient { current = id }
        let candidates: [IngredientSuggestion] = (row.suggestion.map { [$0] } ?? []) + row.alternatives
        var seen: Set<Int64> = []
        var result: [IngredientSuggestion] = []
        for candidate in candidates where candidate.ingredientID != current && index.entry(id: candidate.ingredientID) != nil {
            if seen.insert(candidate.ingredientID).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    // MARK: - Decisions (§7.5)

    /// **Use** on a suggested row: the model proposed X, the user confirms it, and an
    /// alias `name → X` is queued so next time the row resolves at layer 1 instead of
    /// waiting on the model (the model itself never writes the alias — this tap does).
    func useSuggestion(_ rowID: UUID) throws {
        guard let row = draft.row(id: rowID), let suggestion = row.suggestion else { return }
        try choose(rowID, ingredientID: suggestion.ingredientID, addAlias: true)
    }

    /// Point a row at an existing canonical. `addAlias` is the *Same as…* / *Use*
    /// rule (an alias `name → X` is queued, refused if the name already means
    /// something else); false is a plain change of ingredient on an already-decided
    /// row, which teaches nothing. No alias is queued when the name already resolves
    /// to X (it is X's canonical name or one of its aliases): there is nothing to learn.
    func choose(_ rowID: UUID, ingredientID: Int64, addAlias: Bool) throws {
        guard let position = rowIndex(rowID), let entry = index.entry(id: ingredientID) else { return }
        let row = draft.rows[position]
        let target = IngredientRef.existing(ingredientID)
        let needsAlias = addAlias && !alreadyResolves(row.name, to: ingredientID)
        if needsAlias, let refusal = conflict(alias: row.name, target: target, in: draft, decidingRow: row) {
            throw refusal
        }
        var updated = draft
        Self.dropAliases(contributedBy: row, in: &updated)
        Self.decide(&updated.rows[position], ingredient: target, name: entry.canonicalName)
        if needsAlias {
            Self.queueAlias(PendingAlias(alias: Self.trimmed(row.name), target: target), in: &updated)
        }
        Self.prune(&updated)
        draft = updated
    }

    /// Point a row at an ingredient the user created earlier in this session ("New in
    /// this recipe" in the picker). The *Same as…* rule is the same as `choose`: an
    /// alias `name → pending` is queued (the store resolves the pending id inside
    /// its transaction, `RecipeStore.save`), unless the name already normalizes to the
    /// pending name, in which case there is nothing to learn.
    func choosePending(_ rowID: UUID, pendingID: UUID, addAlias: Bool) throws {
        guard let position = rowIndex(rowID), let pending = draft.pendingIngredient(id: pendingID) else { return }
        let row = draft.rows[position]
        let target = IngredientRef.pending(pending.id)
        let needsAlias = addAlias
            && IngredientNormalizer.normalize(row.name) != IngredientNormalizer.normalize(pending.name)
        if needsAlias, let refusal = conflict(alias: row.name, target: target, in: draft, decidingRow: row) {
            throw refusal
        }
        var updated = draft
        Self.dropAliases(contributedBy: row, in: &updated)
        Self.decide(&updated.rows[position], ingredient: target, name: pending.name)
        if needsAlias {
            Self.queueAlias(PendingAlias(alias: Self.trimmed(row.name), target: target), in: &updated)
        }
        Self.prune(&updated)
        draft = updated
    }

    /// **Create** on a new row: a custom canonical (`is_custom = 1`) named after the row.
    /// Two rows creating the same normalized name share one `PendingIngredient` — the
    /// validator refuses duplicates, and two "Harissa" canonicals would fragment the
    /// list forever (the workout app needed a whole merge UI for that). A name that is
    /// already a canonical or alias in the registry is not new either: the row is
    /// pointed at that canonical instead of minting a duplicate.
    func createIngredient(_ rowID: UUID, category: IngredientCategory) {
        guard let position = rowIndex(rowID) else { return }
        let row = draft.rows[position]
        let name = Self.trimmed(row.name)
        let key = IngredientNormalizer.normalize(name)
        // A blank or all-punctuation name would fail validation as a pending name;
        // leave the row undecided so the Save gate keeps pointing at it.
        guard !name.isEmpty, !key.isEmpty else { return }

        var updated = draft
        Self.dropAliases(contributedBy: row, in: &updated)
        if let existingID = index.exactMatch(name) ?? index.aliasMatch(name),
           let entry = index.entry(id: existingID) {
            Self.decide(&updated.rows[position], ingredient: .existing(existingID), name: entry.canonicalName)
        } else {
            let pending: PendingIngredient
            if let known = updated.newIngredients.first(where: { IngredientNormalizer.normalize($0.name) == key }) {
                pending = known
            } else {
                pending = PendingIngredient(name: name, category: category)
                updated.newIngredients.append(pending)
            }
            Self.decide(&updated.rows[position], ingredient: .pending(pending.id), name: pending.name)
        }
        Self.prune(&updated)
        draft = updated
    }

    /// **Keep as text**: stored with a NULL ingredient under *Other* (§6). The one
    /// decided state with `resolution == .none`, exactly as the validator requires.
    func keepAsText(_ rowID: UUID) {
        guard let position = rowIndex(rowID) else { return }
        let row = draft.rows[position]
        var updated = draft
        Self.dropAliases(contributedBy: row, in: &updated)
        updated.rows[position].ingredient = nil
        updated.rows[position].ingredientName = nil
        updated.rows[position].resolution = .none
        updated.rows[position].keepAsText = true
        updated.rows[position].isRemoved = false
        Self.prune(&updated)
        draft = updated
    }

    /// **Not an ingredient**: the line stays in `raw_lines` (§1 "nothing silently
    /// dropped") but gets no `recipe_ingredients` row. A removed line teaches nothing,
    /// so any alias it alone sponsored and any pending ingredient it alone referenced
    /// go with it.
    func remove(_ rowID: UUID) {
        guard let position = rowIndex(rowID) else { return }
        var updated = draft
        updated.rows[position].isRemoved = true
        let removed = updated.rows[position]
        Self.dropAliases(contributedBy: removed, in: &updated)
        Self.prune(&updated)
        draft = updated
    }

    /// Undo a removal. If the row's new ingredient was pruned while it was removed,
    /// the row comes back undecided rather than pointing at a pending id the
    /// validator would refuse as dangling.
    func restore(_ rowID: UUID) {
        guard let position = rowIndex(rowID) else { return }
        var updated = draft
        updated.rows[position].isRemoved = false
        if case .pending(let id)? = updated.rows[position].ingredient, updated.pendingIngredient(id: id) == nil {
            updated.rows[position].ingredient = nil
            updated.rows[position].ingredientName = nil
            updated.rows[position].resolution = .none
        }
        draft = updated
    }

    // MARK: - Field edits

    /// The user retyped the name. Nothing is re-resolved — the user is the authority
    /// on what the line says, and re-running the resolver behind their back would be
    /// the model overriding a person. A stale suggestion (made for the old name) is
    /// cleared. An alias queued for the *old* name is dropped too, unless another row
    /// still sponsors it: an alias is a promise about the name as it was tapped, and
    /// keeping it would teach a mapping for text that no longer exists in the recipe.
    /// A blank name is ignored (the validator would refuse it).
    func setName(_ rowID: UUID, _ name: String) {
        guard let position = rowIndex(rowID) else { return }
        let row = draft.rows[position]
        let trimmed = Self.trimmed(name)
        guard !trimmed.isEmpty, trimmed != row.name else { return }
        var updated = draft
        if IngredientNormalizer.normalize(trimmed) != IngredientNormalizer.normalize(row.name) {
            Self.dropAliases(contributedBy: row, in: &updated)
        }
        updated.rows[position].name = trimmed
        updated.rows[position].suggestion = nil
        draft = updated
    }

    /// nil clears the quantity. Non-finite or negative values are refused here with
    /// the validator's rule, so the field can never hold a value Save would reject.
    func setQuantity(_ rowID: UUID, _ quantity: Double?) {
        guard let position = rowIndex(rowID) else { return }
        if let quantity = quantity, !(quantity.isFinite && quantity >= 0) { return }
        draft.rows[position].quantity = quantity
    }

    /// `unitKey` must be a key from `UnitTable` (or nil for "none"); an unknown key is
    /// ignored. `unitText` is the spelling to display when there is no key; blank
    /// collapses to nil so an empty fragment never renders.
    func setUnit(_ rowID: UUID, unitKey: String?, unitText: String?) {
        guard let position = rowIndex(rowID) else { return }
        if let unitKey = unitKey, !UnitTable.isKnownKey(unitKey) { return }
        var updated = draft
        updated.rows[position].unitKey = unitKey
        updated.rows[position].unitText = Self.nilIfBlank(unitText)
        draft = updated
    }

    func setNote(_ rowID: UUID, _ note: String?) {
        guard let position = rowIndex(rowID) else { return }
        draft.rows[position].note = Self.nilIfBlank(note)
    }

    // MARK: - Alias ownership (§7.5)

    /// Would queuing `alias → target` collide with an owner? Checks, in order: the
    /// registry's alias table, the registry's canonical names (a canonical is
    /// implicitly its own alias — layer 0 would win before the new alias was ever
    /// consulted, so the alias would be dead and misleading), the pending ingredients
    /// of this session, and the aliases already queued in this draft. nil = free.
    func aliasOwnerConflict(alias: String, target: IngredientRef) -> AliasRefusal? {
        conflict(alias: alias, target: target, in: draft, decidingRow: nil)
    }

    /// The write. `RecipeStore.save` validates, opens one transaction, mints the
    /// pending ingredients, writes the aliases (another owner → throws and rolls back
    /// everything), then the recipe and its rows. Errors propagate untouched so the
    /// screen can show `RecipeStoreError.aliasOwnedElsewhere` by name.
    @discardableResult
    func save(into store: RecipeStore) throws -> Int64 {
        try store.save(draft)
    }

    // MARK: - Private

    private func rowIndex(_ rowID: UUID) -> Int? {
        draft.rows.firstIndex { $0.id == rowID }
    }

    /// The name already means `id` in the registry — nothing to teach.
    private func alreadyResolves(_ name: String, to id: Int64) -> Bool {
        let key = IngredientNormalizer.normalize(name)
        if key.isEmpty { return true }   // the validator refuses an empty alias; never queue one
        return index.aliasOwner(normalizedAlias: key) == id || index.exactMatch(name) == id
    }

    /// `decidingRow` is the row about to change: an alias only it sponsors, or a
    /// pending ingredient only it references, is about to be dropped by that very
    /// decision, so it must not be counted as a competing owner (a user changing
    /// their own mind is not a conflict with themselves).
    private func conflict(alias: String, target: IngredientRef, in snapshot: RecipeDraft, decidingRow row: DraftRow?) -> AliasRefusal? {
        let key = IngredientNormalizer.normalize(alias)
        guard !key.isEmpty else { return nil }
        let shown = Self.trimmed(alias)

        if let owner = index.aliasOwner(normalizedAlias: key), IngredientRef.existing(owner) != target {
            return AliasRefusal(alias: shown, ownerName: name(of: .existing(owner), in: snapshot))
        }
        if let owner = index.exactMatch(alias), IngredientRef.existing(owner) != target {
            return AliasRefusal(alias: shown, ownerName: name(of: .existing(owner), in: snapshot))
        }
        for pending in snapshot.newIngredients where IngredientNormalizer.normalize(pending.name) == key {
            let ref = IngredientRef.pending(pending.id)
            if ref == target { continue }
            if let row = row, !Self.isReferenced(ref, excluding: row.id, rows: snapshot.rows) { continue }
            return AliasRefusal(alias: shown, ownerName: pending.name)
        }
        for queued in snapshot.newAliases where IngredientNormalizer.normalize(queued.alias) == key && queued.target != target {
            if let row = row, !Self.isSponsored(queued, excluding: row.id, rows: snapshot.rows) { continue }
            return AliasRefusal(alias: shown, ownerName: name(of: queued.target, in: snapshot))
        }
        return nil
    }

    private func name(of ref: IngredientRef, in snapshot: RecipeDraft) -> String {
        switch ref {
        case .existing(let id):
            return index.entry(id: id)?.canonicalName ?? "another ingredient"
        case .pending(let id):
            return snapshot.pendingIngredient(id: id)?.name ?? "a new ingredient"
        }
    }

    // MARK: - Draft surgery (static and pure: they take the draft being built, never
    // read `self.draft`, so a closure can never overlap a mutation of the published value)

    /// The decided shape every ingredient decision lands in.
    private static func decide(_ row: inout DraftRow, ingredient: IngredientRef, name: String) {
        row.ingredient = ingredient
        row.ingredientName = name
        row.resolution = .user
        row.keepAsText = false
        row.isRemoved = false
        row.suggestion = nil
    }

    /// Remove the aliases this row sponsored — those with its normalized name — unless
    /// another kept row with the same name still points at the alias's target.
    private static func dropAliases(contributedBy row: DraftRow, in draft: inout RecipeDraft) {
        let key = IngredientNormalizer.normalize(row.name)
        guard !key.isEmpty else { return }
        let rows = draft.rows
        draft.newAliases.removeAll { queued in
            IngredientNormalizer.normalize(queued.alias) == key && !isSponsored(queued, excluding: row.id, rows: rows)
        }
    }

    /// Same normalized alias and same target already queued → no duplicate.
    private static func queueAlias(_ alias: PendingAlias, in draft: inout RecipeDraft) {
        let key = IngredientNormalizer.normalize(alias.alias)
        guard !key.isEmpty else { return }
        let duplicate = draft.newAliases.contains {
            IngredientNormalizer.normalize($0.alias) == key && $0.target == alias.target
        }
        if !duplicate {
            draft.newAliases.append(alias)
        }
    }

    /// Drop pending ingredients no kept row references, and aliases that targeted them
    /// (the validator would refuse the dangling target; the user would get a custom
    /// canonical no recipe uses).
    private static func prune(_ draft: inout RecipeDraft) {
        let referenced: Set<UUID> = Set(draft.rows.compactMap { row -> UUID? in
            guard !row.isRemoved, case .pending(let id)? = row.ingredient else { return nil }
            return id
        })
        draft.newIngredients.removeAll { !referenced.contains($0.id) }
        let surviving = Set(draft.newIngredients.map(\.id))
        draft.newAliases.removeAll { queued in
            if case .pending(let id) = queued.target { return !surviving.contains(id) }
            return false
        }
    }

    /// Some kept row other than `rowID` has this normalized name and points at the
    /// alias's target — it keeps the alias alive.
    private static func isSponsored(_ alias: PendingAlias, excluding rowID: UUID, rows: [DraftRow]) -> Bool {
        let key = IngredientNormalizer.normalize(alias.alias)
        return rows.contains { other in
            other.id != rowID && !other.isRemoved && other.ingredient == alias.target
                && IngredientNormalizer.normalize(other.name) == key
        }
    }

    private static func isReferenced(_ ref: IngredientRef, excluding rowID: UUID, rows: [DraftRow]) -> Bool {
        rows.contains { $0.id != rowID && !$0.isRemoved && $0.ingredient == ref }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nilIfBlank(_ text: String?) -> String? {
        guard let text = text else { return nil }
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}
