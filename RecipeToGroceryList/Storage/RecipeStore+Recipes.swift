import Foundation

/// The recipe write path: the one `save`, selection, delete, rename, and the
/// check-state GC that rides along with every selection change (§9). Every
/// mutation of `recipes` / `recipe_ingredients` lives in this file.
///
/// Shape ported from `workout-logger` `Storage/WorkoutStore+Sessions.swift`
/// (@5bffddfb80fc): validate first, then one transaction, with private row-level
/// writers so every statement is written exactly once.
extension RecipeStore {
    // MARK: - The one write path (§1, §7.5)

    /// `RecipeDraft → validate → ONE transaction → rows`. Inside the transaction, in
    /// order: the user's new ingredients (so their ids exist), then the *Same as…* /
    /// *Use* aliases (a term owned by another canonical throws and rolls back
    /// everything — no recipe, no new ingredient, no half alias table), then the
    /// recipe row (unselected: "cooking this" is a separate tap), then one
    /// `recipe_ingredients` row per kept draft row in source order. Removed rows
    /// stay in `raw_lines` only. Returns the recipe id.
    @MainActor
    @discardableResult
    func save(_ draft: RecipeDraft) throws -> Int64 {
        try RecipeValidator.validate(draft)        // parser generous, saver strict
        return try db.transaction {
            var pendingIDs: [UUID: Int64] = [:]
            for pending in draft.newIngredients {
                // Casing is the user's ("Za'atar"), matching is case-insensitive.
                let name = pending.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let slug = try uniqueSlug(forName: name)
                pendingIDs[pending.id] = try insertIngredientRow(slug: slug,
                                                                 canonicalName: name,
                                                                 category: pending.category,
                                                                 isCustom: true)
            }
            var verified: Set<Int64> = []
            for alias in draft.newAliases {
                let target = try databaseID(for: alias.target, pending: pendingIDs, verified: &verified, line: nil)
                try insertAliasRow(alias.alias, ingredientID: target, isCustom: true, ignoringConflicts: false)
            }
            let recipeID = try insertRecipeRow(title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                               source: draft.source,
                                               rawLines: draft.rawLines,
                                               now: Date())
            for (offset, row) in draft.keptRows.enumerated() {
                var rowIngredientID: Int64? = nil
                if !row.keepAsText, let ref = row.ingredient {
                    rowIngredientID = try databaseID(for: ref, pending: pendingIDs, verified: &verified, line: row.rawLine)
                }
                try insertRecipeIngredientRow(recipeID: recipeID, ingredientID: rowIngredientID, row: row, sortOrder: offset)
            }
            return recipeID
        }
    }

    /// Maps a draft reference to a database id: a pending one from this save's own
    /// inserts, an existing one after checking it is real (a typed error beats a
    /// bare FOREIGN KEY failure). `verified` memoizes the existence checks.
    private func databaseID(for ref: IngredientRef, pending: [UUID: Int64],
                            verified: inout Set<Int64>, line: String?) throws -> Int64 {
        switch ref {
        case .pending(let uuid):
            guard let id = pending[uuid] else {
                // The validator already refused these; kept so this function is
                // total even if a caller bypasses it.
                if let line { throw RecipeValidationError.danglingPendingReference(line: line) }
                throw RecipeValidationError.danglingAliasTarget
            }
            return id
        case .existing(let id):
            if !verified.contains(id) {
                guard try ingredientExists(id) else { throw RecipeStoreError.unknownIngredient(id) }
                verified.insert(id)
            }
            return id
        }
    }

    // MARK: - Reads

    /// Newest first, with the `recipe_ingredients` count each row shows.
    func recipes() throws -> [Recipe] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT r.id, r.title, r.source_kind, r.source_ref, r.servings_text, r.raw_lines,
                       r.is_selected, r.created_at, r.updated_at,
                       (SELECT COUNT(*) FROM recipe_ingredients ri WHERE ri.recipe_id = r.id)
                FROM recipes r
                ORDER BY r.created_at DESC, r.id DESC;
            """)
            defer { stmt.finalize() }
            var rows: [Recipe] = []
            while try stmt.step() {
                rows.append(Self.recipe(from: stmt))
            }
            return rows
        }
    }

    func recipe(id: Int64) throws -> Recipe? {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT r.id, r.title, r.source_kind, r.source_ref, r.servings_text, r.raw_lines,
                       r.is_selected, r.created_at, r.updated_at,
                       (SELECT COUNT(*) FROM recipe_ingredients ri WHERE ri.recipe_id = r.id)
                FROM recipes r
                WHERE r.id = ?;
            """)
            defer { stmt.finalize() }
            stmt.bind(int: id, at: 1)
            guard try stmt.step() else { return nil }
            return Self.recipe(from: stmt)
        }
    }

    /// One recipe's rows in source order.
    func recipeIngredients(recipeID: Int64) throws -> [StoredRecipeIngredient] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT id, ingredient_id, raw_line, name, quantity, unit_key, unit_text, note, resolution, sort_order
                FROM recipe_ingredients
                WHERE recipe_id = ?
                ORDER BY sort_order, id;
            """)
            defer { stmt.finalize() }
            stmt.bind(int: recipeID, at: 1)
            var rows: [StoredRecipeIngredient] = []
            while try stmt.step() {
                rows.append(StoredRecipeIngredient(id: stmt.int(0),
                                                   recipeID: recipeID,
                                                   ingredientID: stmt.optionalInt64(1),
                                                   rawLine: stmt.text(2) ?? "",
                                                   name: stmt.text(3) ?? "",
                                                   quantity: stmt.optionalDouble(4),
                                                   unitKey: stmt.text(5),
                                                   unitText: stmt.text(6),
                                                   note: stmt.text(7),
                                                   resolution: RowResolution(rawValue: stmt.text(8) ?? "") ?? RowResolution.none,
                                                   sortOrder: Int(stmt.int(9))))
            }
            return rows
        }
    }

    func selectedRecipeCount() throws -> Int {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT COUNT(*) FROM recipes WHERE is_selected = 1;")
            defer { stmt.finalize() }
            return try stmt.step() ? Int(stmt.int(0)) : 0
        }
    }

    // MARK: - Selection, delete, rename (§9)

    /// "Cooking this" on/off. The check-state GC runs in the SAME transaction: once
    /// no selected recipe contributes an ingredient, its check row goes, so
    /// re-selecting a recipe next week never shows a stale check. That GC is the
    /// only side effect of a toggle. Throws `unknownRecipe` for a missing id.
    @MainActor
    func setSelected(_ recipeID: Int64, _ selected: Bool) throws {
        try db.transaction {
            guard try updateSelectionRow(recipeID, selected: selected) else {
                throw RecipeStoreError.unknownRecipe(recipeID)
            }
            try gcCheckState()
        }
    }

    /// Deletes a recipe; its rows cascade via the FK and the same GC as deselecting
    /// runs (§6). Deleting an id that is already gone is a no-op, so a double swipe
    /// cannot surface an error.
    @MainActor
    func deleteRecipe(_ recipeID: Int64) throws {
        try db.transaction {
            try deleteRecipeRow(recipeID)
            try gcCheckState()
        }
    }

    /// Settings → "Deselect all recipes" (one of the two halves of Done shopping).
    @MainActor
    func deselectAllRecipes() throws {
        try db.transaction {
            try deselectAllRows(now: Date())
            try gcCheckState()
        }
    }

    /// Title only; rows and identity are untouched. Trimmed; blank is refused.
    @MainActor
    func renameRecipe(_ recipeID: Int64, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RecipeStoreError.emptyName }
        try db.transaction {
            guard try updateTitleRow(recipeID, title: trimmed) else {
                throw RecipeStoreError.unknownRecipe(recipeID)
            }
        }
    }

    /// Removes check rows for ingredients no selected recipe contributes any more
    /// (§9 "check-state survival"). Store-internal: always called inside the
    /// transaction that changed selection or deleted a recipe, never on its own —
    /// part of the guarded write surface. The subquery excludes NULL ingredient ids
    /// so `NOT IN` keeps three-valued logic out of the picture.
    func gcCheckState() throws {
        let stmt = try db.prepare("""
            DELETE FROM check_state WHERE ingredient_id NOT IN (
                SELECT ri.ingredient_id
                FROM recipe_ingredients ri
                JOIN recipes r ON r.id = ri.recipe_id
                WHERE r.is_selected = 1 AND ri.ingredient_id IS NOT NULL
            );
        """)
        defer { stmt.finalize() }
        try stmt.step()
    }

    // MARK: - Row-level writes (private; every recipe write funnels through here)

    private func insertRecipeRow(title: String, source: RecipeSource, rawLines: [String], now: Date) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO recipes (title, source_kind, source_ref, servings_text, raw_lines, is_selected, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?);
        """)
        defer { stmt.finalize() }
        let stamp = Self.iso(now)
        stmt.bind(text: title, at: 1)
        stmt.bind(text: source.kind.rawValue, at: 2)
        stmt.bind(optionalText: Self.nilIfBlank(source.ref), at: 3)
        stmt.bind(optionalText: Self.nilIfBlank(source.servingsText), at: 4)
        stmt.bind(text: Self.encodeStringArray(rawLines), at: 5)
        stmt.bind(text: stamp, at: 6)
        stmt.bind(text: stamp, at: 7)
        try stmt.step()
        return db.lastInsertRowID
    }

    private func insertRecipeIngredientRow(recipeID: Int64, ingredientID: Int64?, row: DraftRow, sortOrder: Int) throws {
        let stmt = try db.prepare("""
            INSERT INTO recipe_ingredients
              (recipe_id, ingredient_id, raw_line, name, quantity, unit_key, unit_text, note, resolution, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }
        stmt.bind(int: recipeID, at: 1)
        stmt.bind(optionalInt64: ingredientID, at: 2)
        stmt.bind(text: row.rawLine, at: 3)               // verbatim, never trimmed (§6)
        stmt.bind(text: row.name.trimmingCharacters(in: .whitespacesAndNewlines), at: 4)
        stmt.bind(optionalDouble: row.quantity, at: 5)
        stmt.bind(optionalText: row.unitKey, at: 6)
        stmt.bind(optionalText: Self.nilIfBlank(row.unitText), at: 7)
        stmt.bind(optionalText: Self.nilIfBlank(row.note), at: 8)
        stmt.bind(text: row.resolution.rawValue, at: 9)
        stmt.bind(int: Int64(sortOrder), at: 10)
        try stmt.step()
    }

    /// Returns false when no row matched (unknown id).
    private func updateSelectionRow(_ id: Int64, selected: Bool) throws -> Bool {
        let stmt = try db.prepare("UPDATE recipes SET is_selected = ?, updated_at = ? WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: Int64(selected ? 1 : 0), at: 1)
        stmt.bind(text: Self.iso(Date()), at: 2)
        stmt.bind(int: id, at: 3)
        try stmt.step()
        return db.changes > 0
    }

    private func deselectAllRows(now: Date) throws {
        let stmt = try db.prepare("UPDATE recipes SET is_selected = 0, updated_at = ? WHERE is_selected = 1;")
        defer { stmt.finalize() }
        stmt.bind(text: Self.iso(now), at: 1)
        try stmt.step()
    }

    private func updateTitleRow(_ id: Int64, title: String) throws -> Bool {
        let stmt = try db.prepare("UPDATE recipes SET title = ?, updated_at = ? WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(text: title, at: 1)
        stmt.bind(text: Self.iso(Date()), at: 2)
        stmt.bind(int: id, at: 3)
        try stmt.step()
        return db.changes > 0
    }

    private func deleteRecipeRow(_ id: Int64) throws {
        let stmt = try db.prepare("DELETE FROM recipes WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        try stmt.step()
    }

    /// Column order matches both `recipes()` and `recipe(id:)`.
    private static func recipe(from stmt: Statement) -> Recipe {
        Recipe(id: stmt.int(0),
               title: stmt.text(1) ?? "",
               sourceKind: SourceKind(rawValue: stmt.text(2) ?? "") ?? .text,
               sourceRef: stmt.text(3),
               servingsText: stmt.text(4),
               rawLines: decodeStringArray(stmt.text(5)),
               isSelected: stmt.int(6) != 0,
               lineCount: Int(stmt.int(9)),
               createdAt: date(stmt.text(7)) ?? .distantPast,
               updatedAt: date(stmt.text(8)) ?? .distantPast)
    }
}
