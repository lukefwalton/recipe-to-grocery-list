import Foundation
import os
@testable import RecipeToGroceryList

/// A scripted `RecipeRefining` for the pipeline tests. It **never imports
/// FoundationModels** — the whole point of the protocol seam is that the app's
/// behaviour around the model is driven by a fake here, while the real adapter is
/// verified on-device. Returns one scripted refinement per `refine` call (the last one
/// repeats) and records what it was asked, so a test can assert that headers were
/// filtered out and that `knownIngredients` is the index's canonical list.
///
/// Port of `WorkoutChatLogTests/FakeWorkoutParsing.swift` at
/// `workout-logger@5bffddfb80fc`. `RecipeRefining` is `Sendable`, so the recorded calls
/// sit behind a lock and the class is `@unchecked Sendable` rather than an actor —
/// tests can then read `calls` synchronously. `OSAllocatedUnfairLock` rather than
/// `NSLock`: `refine` is `async`, and `NSLock.lock()` is an error in the Swift 6
/// language mode when called from an asynchronous context.
final class FakeRefiner: RecipeRefining, @unchecked Sendable {
    struct Call: Equatable {
        let lines: [String]
        let knownIngredients: [String]
    }

    private let recorded = OSAllocatedUnfairLock(initialState: [Call]())
    private let sequence: [RecipeRefinement?]

    /// One refinement (or nil = declined) returned on every call.
    init(_ refinement: RecipeRefinement?) {
        self.sequence = [refinement]
    }

    /// One refinement per call, in order; the last repeats once exhausted.
    init(sequence: [RecipeRefinement?]) {
        self.sequence = sequence
    }

    var calls: [Call] {
        recorded.withLock { $0 }
    }

    var callCount: Int { calls.count }

    func refine(lines: [String], knownIngredients: [String]) async -> RecipeRefinement? {
        let index = recorded.withLock { recorded -> Int in
            recorded.append(Call(lines: lines, knownIngredients: knownIngredients))
            return recorded.count - 1
        }
        if index < sequence.count { return sequence[index] }
        if let last = sequence.last { return last }
        return nil
    }
}
