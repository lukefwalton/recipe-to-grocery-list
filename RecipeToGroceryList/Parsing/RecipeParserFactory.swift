import Foundation

/// The one place the FM and non-FM worlds meet (spec §3, §7.6). The on-device model is
/// wired **only** inside `#if canImport(FoundationModels)` *and* only when the OS floor
/// and the runtime availability check both agree; everywhere else the pipeline runs
/// with `refiner == nil` and every feature still works (§1 "Usable without AI"). The
/// `#else` branches keep always-compiled callers — and this file's own signatures —
/// free of any FM symbol. Ported from `WorkoutParserFactory` in
/// `WorkoutChatLog/Parsing/WorkoutParserOrchestrator.swift` at
/// `workout-logger@5bffddfb80fc`.
///
/// Unlike the workout factory this one takes no store: the known ingredient names are
/// passed **per call** (`RecipeRefining.refine(lines:knownIngredients:)`) from the
/// index the pipeline already holds, so there is no snapshot to go stale and no
/// off-main store read.
enum RecipeParserFactory {

    /// Whether the on-device model can be used *right now*: SDK present at compile
    /// time, iOS 26 at run time, and Apple Intelligence reporting the model available.
    /// `canImport` alone proves only that the SDK exists.
    static var onDeviceAIAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationRecipeParser.isModelAvailable()
        }
        return false
        #else
        return false
        #endif
    }

    /// The refiner the pipeline should use, or nil when there is none. The result is a
    /// plain `RecipeRefining?` so `RecipePipeline` and `AppModel` never name an FM type.
    static func makeRefiner() -> RecipeRefining? {
        #if canImport(FoundationModels)
        // Verify the OS floor / symbol names in Xcode; the SDK is the source of truth.
        guard #available(iOS 26.0, *), FoundationRecipeParser.isModelAvailable() else {
            return nil
        }
        return FoundationRecipeParser()
        #else
        return nil
        #endif
    }

    /// §7.6 copy for devices without Apple Intelligence (shown by Confirm / Add when
    /// `onDeviceAIAvailable` is false).
    static let unavailableCopy = "On-device AI isn't available on this device; a few more rows may need a tap."

    /// §7.3 copy for the case where the model *was* wired but declined this recipe
    /// (error, guardrail, unreadable response) and every line fell back to regex.
    static let parsedWithoutAICopy = "Parsed without on-device AI."
}
