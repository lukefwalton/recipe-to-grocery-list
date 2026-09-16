import Foundation

/// The one disciplined layer (spec §1 "One write path", §3). Owns all SQL and the
/// single write path: every input path produces a `RecipeDraft`, the Confirm screen
/// edits it, and `save(_:)` in `RecipeStore+Recipes.swift` is the only thing that
/// turns it into rows. Nothing else writes to the database, and neither the model
/// nor any fuzzy layer ever generates SQL.
///
/// Ported from `workout-logger` `Storage/WorkoutStore.swift` (@5bffddfb80fc) and
/// split by domain the same way so no single file carries the whole store:
///   - `RecipeStore+Ingredients.swift` — the canonical registry: seeding, aliases, the index
///   - `RecipeStore+Recipes.swift`     — the one `save`, recipe reads, selection, delete, check-state GC
///   - `RecipeStore+List.swift`        — the list snapshot, check-off, manual items, Done shopping
/// It is still one type on one connection, so the invariants (one alias owner,
/// check-state GC inside the same transaction as the toggle) are enforced in one
/// place; the split is file organization, not a change of ownership.
///
/// `@unchecked Sendable` is sound because the only stored property is `SQLiteDB`,
/// which serializes whole transaction closures on a recursive connection lock
/// (FULLMUTEX alone only covers single C calls — see `SQLiteDB`'s doc). Writes are
/// additionally `@MainActor`-gated; reads go through `db.readTransaction`, so an
/// off-main read (the list rebuild, the ingredient index) can never interleave into
/// an open write transaction or see half a recipe. Multi-read consumers get
/// consistency via `snapshot(_:)`.
final class RecipeStore: @unchecked Sendable {
    /// The one connection. Internal rather than `private` only because Swift's
    /// `private` is file-scoped and the domain extension files need it. It is still
    /// store-internal by contract: feature code goes through the typed API, so every
    /// recipe write funnels into `save`. Part of the guarded surface —
    /// `scripts/check_store_boundary.sh` fails CI on any `.db` reference outside
    /// `RecipeToGroceryList/Storage/`.
    let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    @MainActor
    func migrate() throws {
        try Schema.migrate(db)
    }

    /// The applied schema version. Wrapped in `readTransaction` like every other
    /// store read — a lone PRAGMA would be harmless mid-transaction, but the
    /// serialized-read rule is only useful if it has no exceptions.
    func schemaVersion() throws -> Int {
        try db.readTransaction { try db.userVersion() }
    }

    // MARK: - Shared plumbing (used by the domain extension files)

    /// Run several reads as one consistent snapshot: a single deferred read
    /// transaction, serialized against writes on this connection, so a save
    /// committing mid-snapshot can't make two reads disagree. Nests harmlessly
    /// around the store's individually-wrapped reads. Read-only by ENFORCEMENT: a
    /// write through the domain APIs hits `transaction`'s nested-write diagnostic,
    /// and even a raw Storage-internal write statement is refused at prepare time
    /// (`sqlite3_stmt_readonly`) — both roll the snapshot back.
    func snapshot<T>(_ body: () throws -> T) throws -> T {
        try db.readTransaction(body)
    }

    /// Row count for one of the store's own tables. Deliberately takes a bare table
    /// identifier rather than SQL text and builds the statement here: a raw-SQL
    /// parameter on a cross-file `internal` helper would be an ad hoc SQL escape
    /// hatch around the store's boundary. The identifier is validated so it can't
    /// smuggle a clause, and the built statement is a SELECT, so this can never write.
    func count(inTable table: String) throws -> Int {
        precondition(table.allSatisfy { $0.isLetter || $0 == "_" },
                     "count(inTable:) takes a bare table identifier, never SQL")
        return try db.readTransaction {
            let stmt = try db.prepare("SELECT COUNT(*) FROM \(table);")
            defer { stmt.finalize() }
            return try stmt.step() ? Int(stmt.int(0)) : 0
        }
    }

    // MARK: - Encoding helpers

    static func iso(_ date: Date) -> String { RecipeDateFormat.string(date) }

    /// Parses an ISO8601 timestamp the store wrote with `iso(_:)`. nil for nil or
    /// unparseable input (e.g. a NULL `checked_at` on an unchecked manual item).
    static func date(_ text: String?) -> Date? { RecipeDateFormat.date(text) }

    /// `raw_lines` is a JSON array so a future pipeline can re-parse without
    /// re-fetching (§6); JSON keeps every line byte-exact, including commas and quotes.
    static func encodeStringArray(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    static func decodeStringArray(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array
    }

    /// Optional text columns store NULL rather than "" or "   ", so a blank note or
    /// unit never renders as an empty fragment. Returns the trimmed text otherwise.
    static func nilIfBlank(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decodes a stored category; the CHECK constraint guarantees a known raw value,
    /// so the fallback only covers a corrupted file.
    static func category(_ raw: String?) -> IngredientCategory {
        IngredientCategory(rawValue: raw ?? "") ?? .other
    }
}
