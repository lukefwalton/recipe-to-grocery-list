import Foundation

/// The grocery list's side of the store (§9): the one snapshot the pure
/// `GroceryListBuilder` consumes, the presence-based check-off keyed by canonical
/// ingredient, manual items, and the two destructive actions that make up Done
/// shopping. Every mutation of `check_state` / `manual_items` lives in this file.
extension RecipeStore {
    // MARK: - The list snapshot

    /// Everything the list is a function of, read in ONE deferred transaction so the
    /// rows, the manual items and the check set can never disagree (a toggle
    /// committing between two of these reads would otherwise show a checked heading
    /// for an ingredient that just left the list). Rows arrive in recipe order
    /// (recipe `created_at`, then id, then `sort_order`), which is the order lines
    /// keep under their heading. Non-isolated: the list rebuilds off the main actor.
    func groceryListInput() throws -> GroceryListInput {
        try db.readTransaction {
            let rows = try selectedRows()
            let items = try manualItemRows()
            let checked = try checkedIngredientIDRows()
            return GroceryListInput(rows: rows, manualItems: items, checkedIngredientIDs: checked)
        }
    }

    func manualItems() throws -> [ManualItem] {
        try db.readTransaction { try manualItemRows() }
    }

    // MARK: - Check-off (§9)

    /// Checks or unchecks a canonical ingredient — across every recipe contributing
    /// to it, since the row is keyed by the ingredient, not the line. No GC here:
    /// that is the selection toggle's one side effect, and a check on an ingredient
    /// that is currently on the list is exactly what this stores.
    @MainActor
    func setChecked(ingredientID: Int64, _ checked: Bool) throws {
        try db.transaction {
            guard try ingredientExists(ingredientID) else { throw RecipeStoreError.unknownIngredient(ingredientID) }
            if checked {
                let stmt = try db.prepare("INSERT OR REPLACE INTO check_state (ingredient_id, checked_at) VALUES (?, ?);")
                defer { stmt.finalize() }
                stmt.bind(int: ingredientID, at: 1)
                stmt.bind(text: Self.iso(Date()), at: 2)
                try stmt.step()
            } else {
                let stmt = try db.prepare("DELETE FROM check_state WHERE ingredient_id = ?;")
                defer { stmt.finalize() }
                stmt.bind(int: ingredientID, at: 1)
                try stmt.step()
            }
        }
    }

    // MARK: - Manual items (§9)

    /// "Also coffee." Trimmed; blank is refused. No resolution runs on it — a manual
    /// item is never merged with a recipe ingredient (that is what Add → Paste is for).
    @MainActor
    @discardableResult
    func addManualItem(_ text: String) throws -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RecipeStoreError.blankManualItem }
        return try db.transaction {
            let stmt = try db.prepare("INSERT INTO manual_items (text, checked_at, created_at) VALUES (?, NULL, ?);")
            defer { stmt.finalize() }
            stmt.bind(text: trimmed, at: 1)
            stmt.bind(text: Self.iso(Date()), at: 2)
            try stmt.step()
            return db.lastInsertRowID
        }
    }

    @MainActor
    func setManualItemChecked(_ id: Int64, _ checked: Bool) throws {
        try db.transaction {
            let stmt = try db.prepare("UPDATE manual_items SET checked_at = ? WHERE id = ?;")
            defer { stmt.finalize() }
            stmt.bind(optionalText: checked ? Self.iso(Date()) : nil, at: 1)
            stmt.bind(int: id, at: 2)
            try stmt.step()
        }
    }

    @MainActor
    func deleteManualItem(_ id: Int64) throws {
        try db.transaction {
            let stmt = try db.prepare("DELETE FROM manual_items WHERE id = ?;")
            defer { stmt.finalize() }
            stmt.bind(int: id, at: 1)
            try stmt.step()
        }
    }

    // MARK: - Destructive actions (§9, both confirmed in the UI)

    /// Settings → "Clear checked": every check row and every checked manual item.
    /// Selection is untouched, so the list re-renders unchecked.
    @MainActor
    func clearChecked() throws {
        try db.transaction { try clearCheckedRows() }
    }

    /// "Done shopping" = Clear checked + Deselect all recipes, one button, one
    /// confirmation, ONE transaction — so an interrupted tap can never leave the
    /// checks gone but the recipes still selected (or the reverse). The GC after the
    /// deselect is what empties `check_state` of anything Clear checked did not.
    @MainActor
    func doneShopping() throws {
        try db.transaction {
            try clearCheckedRows()
            try deselectSelectedRecipeRows(now: Date())
            try gcCheckState()
        }
    }

    // MARK: - Private row helpers

    /// Column order: ri.id, ri.recipe_id, r.title, ri.ingredient_id, i.canonical_name,
    /// i.category, ri.name, ri.quantity, ri.unit_key, ri.unit_text, ri.note, ri.sort_order.
    /// LEFT JOIN so kept-as-text rows (NULL ingredient) still arrive, with the
    /// ingredient columns NULL.
    private func selectedRows() throws -> [SelectedRow] {
        let stmt = try db.prepare("""
            SELECT ri.id, ri.recipe_id, r.title, ri.ingredient_id, i.canonical_name, i.category,
                   ri.name, ri.quantity, ri.unit_key, ri.unit_text, ri.note, ri.sort_order
            FROM recipe_ingredients ri
            JOIN recipes r ON r.id = ri.recipe_id
            LEFT JOIN ingredients i ON i.id = ri.ingredient_id
            WHERE r.is_selected = 1
            ORDER BY r.created_at, r.id, ri.sort_order, ri.id;
        """)
        defer { stmt.finalize() }
        var rows: [SelectedRow] = []
        while try stmt.step() {
            let ingredientID = stmt.optionalInt64(3)
            rows.append(SelectedRow(rowID: stmt.int(0),
                                    recipeID: stmt.int(1),
                                    recipeTitle: stmt.text(2) ?? "",
                                    ingredientID: ingredientID,
                                    ingredientName: ingredientID == nil ? nil : stmt.text(4),
                                    category: ingredientID == nil ? nil : Self.category(stmt.text(5)),
                                    name: stmt.text(6) ?? "",
                                    quantity: stmt.optionalDouble(7),
                                    unitKey: stmt.text(8),
                                    unitText: stmt.text(9),
                                    note: stmt.text(10),
                                    sortOrder: Int(stmt.int(11))))
        }
        return rows
    }

    private func manualItemRows() throws -> [ManualItem] {
        let stmt = try db.prepare("SELECT id, text, checked_at, created_at FROM manual_items ORDER BY created_at, id;")
        defer { stmt.finalize() }
        var items: [ManualItem] = []
        while try stmt.step() {
            items.append(ManualItem(id: stmt.int(0),
                                    text: stmt.text(1) ?? "",
                                    checkedAt: Self.date(stmt.text(2)),
                                    createdAt: Self.date(stmt.text(3)) ?? .distantPast))
        }
        return items
    }

    private func checkedIngredientIDRows() throws -> Set<Int64> {
        let stmt = try db.prepare("SELECT ingredient_id FROM check_state;")
        defer { stmt.finalize() }
        var ids: Set<Int64> = []
        while try stmt.step() {
            ids.insert(stmt.int(0))
        }
        return ids
    }

    private func clearCheckedRows() throws {
        try db.execute("DELETE FROM check_state;")
        try db.execute("DELETE FROM manual_items WHERE checked_at IS NOT NULL;")
    }

    /// Same statement as `RecipeStore+Recipes.swift`'s `deselectAllRows`, kept
    /// private here on purpose: the cross-file `internal` write surface stays
    /// exactly the set `scripts/check_store_boundary.sh` guards (`insertIngredientRow`,
    /// `insertAliasRow`, `gcCheckState`, `.db`), at the cost of one duplicated line.
    private func deselectSelectedRecipeRows(now: Date) throws {
        let stmt = try db.prepare("UPDATE recipes SET is_selected = 0, updated_at = ? WHERE is_selected = 1;")
        defer { stmt.finalize() }
        stmt.bind(text: Self.iso(now), at: 1)
        try stmt.step()
    }
}
