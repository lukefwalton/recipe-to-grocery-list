import Foundation

/// Why a draft was refused at the write gate. Row-level cases carry the raw line
/// so the Confirm screen can point at the offender; nothing here carries SQL.
enum RecipeValidationError: Error, Equatable {
    case emptyTitle
    case noRawLines
    case noRows
    /// The row is still in the *New* or *Suggested* state (§7.5): it needs a tap.
    /// Accepting a suggested row silently would let the model write an alias.
    case rowStillNeedsDecision(line: String)
    case rowEmptyName(line: String)
    case rowBadQuantity(line: String)
    case rowUnknownUnit(line: String)
    /// `keepAsText` and `ingredient` disagree with each other or with `resolution`
    /// (kept as text ⇒ no ingredient and resolution `.none`; an ingredient ⇒ a
    /// resolution other than `.none`).
    case rowInconsistent(line: String)
    /// The row points at a `.pending(uuid)` that is not in `newIngredients`.
    case danglingPendingReference(line: String)
    case pendingIngredientEmptyName
    /// Two pending ingredients normalize (§7.1) to the same name; the payload is the
    /// second one's name as written.
    case duplicatePendingIngredient(String)
    case emptyAlias
    /// An alias points at a `.pending(uuid)` that is not in `newIngredients`.
    case danglingAliasTarget
}

/// Save guardrails (spec §1 "one write path", §7.5). The parser is generous about
/// what it proposes; the saver is strict about what it stores, so malformed data
/// never lands silently. Runs *before* `RecipeStore.save` opens its transaction, so
/// a bad draft cannot even start a write. Same shape as `workout-logger`
/// `Storage/WorkoutValidator.swift` (@5bffddfb80fc): a plain enum that throws.
///
/// What is checked here is everything that can be known without the database.
/// Existence of `.existing(id)` references and alias ownership are the store's
/// job, inside the transaction, where the answer cannot go stale.
enum RecipeValidator {
    static func validate(_ draft: RecipeDraft) throws {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecipeValidationError.emptyTitle
        }
        guard !draft.rawLines.isEmpty else { throw RecipeValidationError.noRawLines }
        let kept = draft.keptRows
        guard !kept.isEmpty else { throw RecipeValidationError.noRows }

        // Pending ingredients first, so row and alias references can be checked
        // against the complete set.
        var pendingIDs: Set<UUID> = []
        var seenNames: Set<String> = []
        for pending in draft.newIngredients {
            let name = pending.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = IngredientNormalizer.normalize(name)
            // A name that is only punctuation or a parenthetical normalizes to
            // nothing and would never resolve again — refuse it like a blank.
            guard !name.isEmpty, !key.isEmpty else { throw RecipeValidationError.pendingIngredientEmptyName }
            guard !seenNames.contains(key) else { throw RecipeValidationError.duplicatePendingIngredient(name) }
            seenNames.insert(key)
            pendingIDs.insert(pending.id)
        }

        for row in kept {
            let line = row.rawLine
            if row.blocksSave { throw RecipeValidationError.rowStillNeedsDecision(line: line) }
            guard !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecipeValidationError.rowEmptyName(line: line)
            }
            if let quantity = row.quantity {
                // 0 is legal ("0 to taste" edits happen); inf/nan/negative never are.
                guard quantity.isFinite, quantity >= 0 else { throw RecipeValidationError.rowBadQuantity(line: line) }
            }
            if let unitKey = row.unitKey {
                guard UnitTable.isKnownKey(unitKey) else { throw RecipeValidationError.rowUnknownUnit(line: line) }
            }
            // Exactly one of (kept as text, has an ingredient). The (false, nil)
            // combination is the New/Suggested state and was refused above.
            switch (row.keepAsText, row.ingredient) {
            case (true, nil):
                guard row.resolution == .none else { throw RecipeValidationError.rowInconsistent(line: line) }
            case (false, let ref?):
                guard row.resolution != .none else { throw RecipeValidationError.rowInconsistent(line: line) }
                if case .pending(let id) = ref, !pendingIDs.contains(id) {
                    throw RecipeValidationError.danglingPendingReference(line: line)
                }
            default:
                throw RecipeValidationError.rowInconsistent(line: line)
            }
        }

        for alias in draft.newAliases {
            guard !IngredientNormalizer.normalize(alias.alias).isEmpty else { throw RecipeValidationError.emptyAlias }
            if case .pending(let id) = alias.target, !pendingIDs.contains(id) {
                throw RecipeValidationError.danglingAliasTarget
            }
        }
    }
}
