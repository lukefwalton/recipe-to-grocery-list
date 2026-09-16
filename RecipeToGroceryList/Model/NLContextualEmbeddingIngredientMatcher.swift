#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Layer 3's real implementation (spec §7.4): Apple's on-device
/// `NLContextualEmbedding` (BERT-style; model assets ship in the **system** catalog,
/// so zero app size). The entire file is wrapped in `#if canImport(NaturalLanguage)`
/// so not one `NLContextualEmbedding` symbol leaks into always-compiled code; callers
/// only ever see the `IngredientEmbedding` protocol, and tests use a fake.
///
/// Port of `Model/NLContextualEmbeddingExerciseMatcher.swift` at
/// `workout-logger@5bffddfb80fc`, renamed; English-only because the seed, unit table
/// and prompts are English (§2).
///
/// NOT COMPILED HERE (Linux, no NaturalLanguage SDK) and **NOT VERIFIED ON DEVICE.**
/// The assets download asynchronously and are documented to **fail to load in the
/// simulator**, so this is gated exactly like `FoundationRecipeParser`: a compile gate
/// **and** a runtime load check, with any failure falling through to fuzzy/LLM. The
/// symbol names / availability below must be verified in Xcode against the installed
/// SDK — the SDK is the source of truth, not this file.
@available(iOS 17.0, *)
final class NLContextualEmbeddingIngredientMatcher: IngredientEmbedding {
    private let model: NLContextualEmbedding
    /// Whether `model.load()` has succeeded. **Not latched at init**: assets download
    /// asynchronously, so readiness is re-evaluated on demand (`ensureLoaded`) and can
    /// flip to true later in the same session once the download finishes — no view/
    /// model recreation required.
    private var loaded = false
    private var requestedAssets = false

    private init?(language: NLLanguage) {
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        self.model = model
        _ = ensureLoaded()   // load now if assets are already present; else kick off the request
    }

    /// Load the model if assets are present and it isn't loaded yet; otherwise kick off
    /// the async asset request (once) and report not-ready for now. Idempotent and
    /// non-blocking — it never waits on a download, so a not-ready return simply falls
    /// through to fuzzy/LLM. `hasAvailableAssets` / `load()` / `requestAssets` are the
    /// documented entry points — verify exact spelling in Xcode.
    @discardableResult
    private func ensureLoaded() -> Bool {
        if loaded { return true }
        if model.hasAvailableAssets {
            loaded = (try? { try model.load(); return true }()) ?? false
        } else if !requestedAssets {
            requestedAssets = true
            model.requestAssets { _, _ in }   // ready flips on a later `ensureLoaded`
        }
        return loaded
    }

    /// Build a matcher only when the SDK reports a usable model on this OS; otherwise
    /// nil so the factory substitutes `NoopEmbedding`. English-only at launch.
    static func makeIfAvailable() -> NLContextualEmbeddingIngredientMatcher? {
        NLContextualEmbeddingIngredientMatcher(language: .english)
    }

    /// Re-checks readiness each call (re-attempting `load()` if assets have since
    /// arrived), so layer 3 activates mid-session once the download completes.
    var isReady: Bool { ensureLoaded() }

    func vector(for text: String) -> [Double]? {
        guard ensureLoaded() else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let result = try model.embeddingResult(for: trimmed, language: .english)
            // Mean-pool the per-token vectors. Accelerate `vDSP` would speed this up on
            // device; the reference `EmbeddingMath.meanPool` keeps it correct + testable.
            var tokenVectors: [[Double]] = []
            // The closure's first parameter is `[Double]`; append it directly with the
            // parameter types spelled out (the workout port found `.map(Double.init)`
            // made the expression ambiguous for the compiler).
            result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { (vector: [Double], _: Range<String.Index>) -> Bool in
                tokenVectors.append(vector)
                return true
            }
            return EmbeddingMath.meanPool(tokenVectors)
        } catch {
            return nil   // opportunistic: any failure → no semantic vector, fall through
        }
    }
}
#endif
