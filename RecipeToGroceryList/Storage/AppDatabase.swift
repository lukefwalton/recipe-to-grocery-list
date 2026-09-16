import Foundation

/// Composition root for the on-device database. Opens the SQLite file in the app's
/// private Application Support directory, migrates the schema, and upserts the
/// canonical ingredient library. The whole app holds exactly one store.
///
/// Ported from `workout-logger` `Storage/AppDatabase.swift` (@5bffddfb80fc) with one
/// deliberate departure (spec §3 "deliberately different"): the file lives in the
/// private sandbox, NOT the App Group container. The Share Extension never opens
/// the database — it only writes the one-way inbox — so there is no second process
/// to share a file with, and the connection story stays single-process.
enum AppDatabase {
    static let fileName = "recipes.sqlite"

    /// `<Application Support>/recipes.sqlite`. Application Support does not exist
    /// until something creates it, so `create: true` does that on first launch.
    static func databaseURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        return support.appendingPathComponent(fileName)
    }

    // @MainActor because it drives the mutating store APIs (migrate, seed), which
    // carry the single-connection write invariant. Called from the app's launch
    // path, which is already main-actor isolated.
    @MainActor
    static func makeStore() throws -> RecipeStore {
        let db = try SQLiteDB(path: databaseURL().path)
        let store = RecipeStore(db: db)
        try store.migrate()
        try store.seedIngredientsIfNeeded(IngredientSeed.load())
        return store
    }
}
