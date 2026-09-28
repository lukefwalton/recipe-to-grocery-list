import Foundation

/// The canonical ingredient registry (spec §6, §7.1): seeding, the alias table with
/// its one-owner PRIMARY KEY, and the reads the resolution layers build
/// `IngredientIndex` from. Every write to `ingredients` / `ingredient_aliases`
/// lives here; `save` calls the row-level writers below inside its own transaction.
///
/// Ported from `workout-logger` `Storage/WorkoutStore+Exercises.swift`
/// (@5bffddfb80fc): ingredient identity works exactly like exercise identity
/// (`id` + `slug` + `canonical_name`, aliases keyed by the normalized term). The
/// resolution stack itself moved out of the store into `Parsing/IngredientResolver`
/// because it runs against an in-memory index, not per-row SQL.
extension RecipeStore {
    // MARK: - Seeding

    /// Upserts the canonical library, keyed on the stable `slug`. A brand new slug
    /// is inserted; an existing slug keeps its row — including the user's possibly
    /// renamed `canonical_name` and its `is_custom` flag — while refreshing the
    /// seed-owned `category` and re-adding any missing aliases with `INSERT OR
    /// IGNORE`, so an alias the user already gave another owner is left alone. That
    /// makes a post-launch seed expansion non-destructive and calling this on every
    /// launch idempotent: the count only grows when the seed itself does.
    @MainActor
    func seedIngredientsIfNeeded(_ seeds: [SeedIngredient]) throws {
        try db.transaction {
            for seed in seeds {
                let id: Int64
                if let existing = try ingredientID(slug: seed.slug) {
                    try updateSeedCategory(existing, category: seed.category)
                    id = existing
                } else {
                    id = try insertIngredientRow(slug: seed.slug,
                                                 canonicalName: seed.canonicalName,
                                                 category: seed.category,
                                                 isCustom: false)
                }
                for alias in seed.aliases {
                    try insertAliasRow(alias, ingredientID: id, isCustom: false, ignoringConflicts: true)
                }
            }
        }
    }

    // MARK: - Reads

    func ingredientCount() throws -> Int { try count(inTable: "ingredients") }

    func ingredient(id: Int64) throws -> Ingredient? {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT slug, canonical_name, category, is_custom FROM ingredients WHERE id = ?;")
            defer { stmt.finalize() }
            stmt.bind(int: id, at: 1)
            guard try stmt.step() else { return nil }
            return Ingredient(id: id,
                              slug: stmt.text(0) ?? "",
                              canonicalName: stmt.text(1) ?? "",
                              category: Self.category(stmt.text(2)),
                              isCustom: stmt.int(3) != 0)
        }
    }

    /// Every canonical, display-sorted, for the *Same as…* picker.
    func allIngredients() throws -> [Ingredient] {
        try db.readTransaction {
            let stmt = try db.prepare("""
                SELECT id, slug, canonical_name, category, is_custom
                FROM ingredients
                ORDER BY canonical_name COLLATE NOCASE, id;
            """)
            defer { stmt.finalize() }
            var rows: [Ingredient] = []
            while try stmt.step() {
                rows.append(Ingredient(id: stmt.int(0),
                                       slug: stmt.text(1) ?? "",
                                       canonicalName: stmt.text(2) ?? "",
                                       category: Self.category(stmt.text(3)),
                                       isCustom: stmt.int(4) != 0))
            }
            return rows
        }
    }

    /// Owned aliases bucketed by ingredient — one query, sorted for a stable index.
    func aliasesByIngredient() throws -> [Int64: [String]] {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT ingredient_id, alias FROM ingredient_aliases ORDER BY ingredient_id, alias;")
            defer { stmt.finalize() }
            var map: [Int64: [String]] = [:]
            while try stmt.step() {
                map[stmt.int(0), default: []].append(stmt.text(1) ?? "")
            }
            return map
        }
    }

    /// The registry as the resolution layers see it (§7.4), read in ONE snapshot so
    /// the canonicals and their aliases can never disagree. Ordered by id so the
    /// semantic layer's cached embeddings line up run to run. Non-isolated: the
    /// pipeline builds its resolver off the main actor.
    func ingredientIndex() throws -> IngredientIndex {
        try db.readTransaction {
            let aliases = try aliasesByIngredient()
            let stmt = try db.prepare("SELECT id, canonical_name, category FROM ingredients ORDER BY id;")
            defer { stmt.finalize() }
            var entries: [IngredientIndexEntry] = []
            while try stmt.step() {
                let id = stmt.int(0)
                entries.append(IngredientIndexEntry(id: id,
                                                    canonicalName: stmt.text(1) ?? "",
                                                    category: Self.category(stmt.text(2)),
                                                    aliases: aliases[id] ?? []))
            }
            return IngredientIndex(entries: entries)
        }
    }

    /// The current owner of an alias, looked up by the same §7.1 normalization the
    /// alias table is keyed on — a single primary-key hit. nil when unowned or when
    /// the term normalizes to nothing.
    func aliasOwner(_ rawAlias: String) throws -> Int64? {
        let alias = Self.normalizeAlias(rawAlias)
        guard !alias.isEmpty else { return nil }
        return try db.readTransaction { try aliasOwnerRow(alias) }
    }

    func ingredientID(slug: String) throws -> Int64? {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT id FROM ingredients WHERE slug = ? LIMIT 1;")
            defer { stmt.finalize() }
            stmt.bind(text: slug, at: 1)
            return try stmt.step() ? stmt.int(0) : nil
        }
    }

    /// Whether an `.existing(id)` reference is real. A read; used by `save` and
    /// `setChecked` to turn a would-be FK failure into a typed error.
    func ingredientExists(_ id: Int64) throws -> Bool {
        try db.readTransaction {
            let stmt = try db.prepare("SELECT 1 FROM ingredients WHERE id = ? LIMIT 1;")
            defer { stmt.finalize() }
            stmt.bind(int: id, at: 1)
            return try stmt.step()
        }
    }

    // MARK: - Name normalization

    /// Alias storage/lookup key. The ONE normalization (§7.1) is
    /// `IngredientNormalizer.normalize`, shared with every matching layer so the
    /// alias table's PRIMARY KEY and the resolver can never disagree; this is a
    /// named seam, not a second rule.
    static func normalizeAlias(_ raw: String) -> String { IngredientNormalizer.normalize(raw) }

    /// Slug for a user-created canonical, the same way the seed build authors its
    /// slugs, so a custom that later ships as a seed entry lines up on the same key.
    static func slugify(_ name: String) -> String { IngredientNormalizer.slugify(name) }

    // MARK: - Row-level writes (store-internal)
    // Internal only for the cross-file transaction in `save` — part of the guarded
    // surface that scripts/check_store_boundary.sh keeps out of feature code.

    @discardableResult
    func insertIngredientRow(slug: String, canonicalName: String, category: IngredientCategory, isCustom: Bool) throws -> Int64 {
        let stmt = try db.prepare("""
            INSERT INTO ingredients (slug, canonical_name, category, is_custom, created_at)
            VALUES (?, ?, ?, ?, ?);
        """)
        defer { stmt.finalize() }
        stmt.bind(text: slug, at: 1)
        stmt.bind(text: canonicalName, at: 2)
        stmt.bind(text: category.rawValue, at: 3)
        stmt.bind(int: Int64(isCustom ? 1 : 0), at: 4)
        stmt.bind(text: Self.iso(Date()), at: 5)
        try stmt.step()
        return db.lastInsertRowID
    }

    /// Writes a normalized alias. `ignoringConflicts` true is the seed's rule
    /// (`INSERT OR IGNORE`: keep whatever owner exists). false is the Confirm
    /// screen's rule (§7.5): the same owner is a no-op, a *different* owner throws
    /// `RecipeStoreError.aliasOwnedElsewhere` naming that owner, so the enclosing
    /// save rolls back and the user picks explicitly. Terms that normalize to
    /// nothing are skipped. Safe to pass text that is already normalized.
    func insertAliasRow(_ rawAlias: String, ingredientID: Int64, isCustom: Bool, ignoringConflicts: Bool) throws {
        let alias = Self.normalizeAlias(rawAlias)
        guard !alias.isEmpty else { return }
        if !ignoringConflicts, let owner = try aliasOwnerRow(alias) {
            if owner == ingredientID { return }
            let ownerName = try canonicalNameRow(id: owner) ?? ""
            throw RecipeStoreError.aliasOwnedElsewhere(alias: alias, ownerName: ownerName)
        }
        let sql = ignoringConflicts
            ? "INSERT OR IGNORE INTO ingredient_aliases (alias, ingredient_id, is_custom) VALUES (?, ?, ?);"
            : "INSERT INTO ingredient_aliases (alias, ingredient_id, is_custom) VALUES (?, ?, ?);"
        let stmt = try db.prepare(sql)
        defer { stmt.finalize() }
        stmt.bind(text: alias, at: 1)
        stmt.bind(int: ingredientID, at: 2)
        stmt.bind(int: Int64(isCustom ? 1 : 0), at: 3)
        try stmt.step()
    }

    /// A unique slug for a user-created ingredient: the slugified name, suffixed
    /// `_2`, `_3`, … only if that slug is already taken, so a custom never collides
    /// with a seed slug. A name that slugifies to nothing gets the stem "ingredient".
    func uniqueSlug(forName name: String) throws -> String {
        let base = Self.slugify(name)
        let stem = base.isEmpty ? "ingredient" : base
        var candidate = stem
        var n = 2
        while try ingredientID(slug: candidate) != nil {
            candidate = "\(stem)_\(n)"
            n += 1
        }
        return candidate
    }

    // MARK: - Private row helpers

    /// Refreshes the seed-owned category on reseed without touching the (possibly
    /// user-renamed) display name or the is_custom flag. A custom row that a later
    /// seed happens to share a slug with keeps the category the user picked.
    private func updateSeedCategory(_ id: Int64, category: IngredientCategory) throws {
        let stmt = try db.prepare("UPDATE ingredients SET category = ? WHERE id = ? AND is_custom = 0;")
        defer { stmt.finalize() }
        stmt.bind(text: category.rawValue, at: 1)
        stmt.bind(int: id, at: 2)
        try stmt.step()
    }

    /// Raw owner lookup for an already-normalized alias; callers hold the transaction.
    private func aliasOwnerRow(_ alias: String) throws -> Int64? {
        let stmt = try db.prepare("SELECT ingredient_id FROM ingredient_aliases WHERE alias = ? LIMIT 1;")
        defer { stmt.finalize() }
        stmt.bind(text: alias, at: 1)
        return try stmt.step() ? stmt.int(0) : nil
    }

    private func canonicalNameRow(id: Int64) throws -> String? {
        let stmt = try db.prepare("SELECT canonical_name FROM ingredients WHERE id = ?;")
        defer { stmt.finalize() }
        stmt.bind(int: id, at: 1)
        return try stmt.step() ? stmt.text(0) : nil
    }
}
