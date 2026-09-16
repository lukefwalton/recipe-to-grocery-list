import Foundation

/// The SQLite schema and its forward-only migrations, tracked by
/// `PRAGMA user_version` (spec §3 "inherit as-is", §6). A fresh install lays the
/// whole current schema down in one transaction and stamps the latest version, so
/// a half-applied schema can never be left behind; an installed database only
/// ever moves forward, one versioned step per transaction.
///
/// Ported from `workout-logger` `Storage/Schema.swift` (@5bffddfb80fc), minus the
/// legacy-shape guard (this app has never shipped a different shape, so there is
/// nothing to refuse). The v1 literal below is the SPEC §6 SQL verbatim plus the
/// lookup indexes the store's hot queries need; `SchemaTests` pins the table set
/// and the version stamp, and `scratchpad/sql_check.py` diffs the literal against
/// the spec block during review.
enum Schema {
    static let latestVersion = 1

    static func migrate(_ db: SQLiteDB) throws {
        let version = try db.userVersion()
        if version == 0 {
            // Fresh install: every version in one transaction, then the stamp.
            try db.transaction {
                try db.execute(v1)
                try db.setUserVersion(latestVersion)
            }
            return
        }
        // Forward, non-destructive migrations for an installed database. Each
        // future step bumps user_version inside its own transaction:
        //
        //   if version < 2 {
        //       try db.transaction {
        //           try db.execute(v2)
        //           try db.setUserVersion(2)
        //       }
        //   }
        //
        // At v1 there is nothing to do: an already-stamped database is a no-op.
    }

    // Every closed vocabulary (category, source_kind, resolution) is a CHECK
    // constraint so the database — not just the save path — rejects bad data from
    // any future writer. The raw values of `IngredientCategory`, `SourceKind` and
    // `RowResolution` are exactly these literals.
    //
    // Identity mirrors exercises in workout-logger: `ingredients.id` is the
    // immutable rowid rows reference, `slug` the stable seed key, `canonical_name`
    // the user-renamable display name (not UNIQUE — nothing points at the name).
    // `ingredient_aliases.alias` is the PRIMARY KEY so an ambiguous term can only
    // ever have one owner and falls through to "ask" instead of resolving wrong.
    //
    // `recipe_ingredients.ingredient_id` is nullable with ON DELETE SET NULL: a
    // row whose ingredient disappears becomes a kept-as-text row rather than
    // vanishing, which is how "nothing silently dropped" survives an ingredient
    // merge/delete when v1.1 adds one. `check_state` is presence-based and keyed
    // by the canonical ingredient, so a check survives list regeneration.
    private static let v1 = """
    CREATE TABLE ingredients (
        id              INTEGER PRIMARY KEY,
        slug            TEXT NOT NULL UNIQUE,            -- import/export key, never changes
        canonical_name  TEXT NOT NULL,                   -- user-renamable; seed never overwrites
        category        TEXT NOT NULL DEFAULT 'other'
                        CHECK (category IN ('produce','dairy','meat','seafood','bakery','pantry','frozen','other')),
        is_custom       INTEGER NOT NULL DEFAULT 0,      -- 1 = user-created via Confirm
        created_at      TEXT NOT NULL
    );

    CREATE TABLE ingredient_aliases (
        alias           TEXT PRIMARY KEY,                -- normalized (§7.1); PK = one owner per term
        ingredient_id   INTEGER NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
        is_custom       INTEGER NOT NULL DEFAULT 0       -- 1 = written by a "same as…" tap
    );

    CREATE TABLE recipes (
        id              INTEGER PRIMARY KEY,
        title           TEXT NOT NULL,
        source_kind     TEXT NOT NULL CHECK (source_kind IN ('url','text','photo')),
        source_ref      TEXT,                            -- final URL for 'url'; NULL otherwise
        servings_text   TEXT,                            -- raw recipeYield, display only
        raw_lines       TEXT NOT NULL,                   -- JSON array of the lines we were given
        is_selected     INTEGER NOT NULL DEFAULT 0,
        created_at      TEXT NOT NULL,
        updated_at      TEXT NOT NULL
    );

    CREATE TABLE recipe_ingredients (
        id              INTEGER PRIMARY KEY,
        recipe_id       INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
        ingredient_id   INTEGER REFERENCES ingredients(id) ON DELETE SET NULL,  -- NULL = kept as free text
        raw_line        TEXT NOT NULL,                   -- always kept, verbatim
        name            TEXT NOT NULL,                   -- cleaned name as written ("veggie broth")
        quantity        REAL,                            -- parsed, never converted
        unit_key        TEXT,                            -- normalized unit (§8) or NULL
        unit_text       TEXT,                            -- unit as written, for display
        note            TEXT,                            -- "diced", "divided", "2–3"
        resolution      TEXT NOT NULL
                        CHECK (resolution IN ('exact','alias','loose','fuzzy','embedding','llm','user','none')),
        sort_order      INTEGER NOT NULL
    );

    CREATE TABLE check_state (
        ingredient_id   INTEGER PRIMARY KEY REFERENCES ingredients(id) ON DELETE CASCADE,
        checked_at      TEXT NOT NULL                    -- row present = checked
    );

    CREATE TABLE manual_items (
        id              INTEGER PRIMARY KEY,
        text            TEXT NOT NULL,
        checked_at      TEXT,                            -- NULL = unchecked
        created_at      TEXT NOT NULL
    );

    CREATE INDEX idx_ingredients_category ON ingredients(category);
    CREATE INDEX idx_ingredient_aliases_ingredient ON ingredient_aliases(ingredient_id);
    CREATE INDEX idx_recipe_ingredients_recipe ON recipe_ingredients(recipe_id);
    CREATE INDEX idx_recipe_ingredients_ingredient ON recipe_ingredients(ingredient_id);
    CREATE INDEX idx_recipes_selected ON recipes(is_selected);
    """
}
