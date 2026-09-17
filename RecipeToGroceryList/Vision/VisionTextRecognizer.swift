#if canImport(Vision)
import Foundation
import Vision
import os

/// The real on-device text recognizer (spec §5.3), entirely inside
/// `#if canImport(Vision)` so not one Vision symbol reaches always-compiled code.
/// It conforms to the common `TextRecognizing` protocol; the photo screen and the
/// tests only ever see that protocol.
///
/// On-device and private: `VNRecognizeTextRequest` runs locally, and no image or
/// recognized text leaves the phone — the image is processed in memory and never
/// written anywhere (the privacy screen says exactly that). Accurate recognition
/// with language correction, tuned for a printed cookbook page where each
/// physical line is one candidate ingredient.
///
/// Ported from `WorkoutChatLog/Vision/VisionTextRecognizer.swift` at
/// `workout-logger@5bffddfb80fc`. The difference is the grouping: that app reads a
/// workout sheet one observation per line and keeps each confidence for its review
/// list, while here observations are merged into physical lines by
/// `PhotoLineMerger` (§5.3) and confidence is not surfaced — the Confirm screen is
/// the review step for every capture path.
///
/// NOT COMPILED HERE (Linux, no Vision SDK). The symbol names below —
/// `VNRecognizeTextRequest`, `VNImageRequestHandler(data:options:)`, `.accurate`,
/// `recognitionLanguages`, `topCandidates(_:)` — must be verified against the
/// installed SDK in Xcode; the SDK is the source of truth.
struct VisionTextRecognizer: TextRecognizing {
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "RecipeToGroceryList",
                             category: "OCR")

    func recognizeLines(in imageData: Data) async -> [String] {
        // `perform` is synchronous and CPU-heavy (accurate recognition over a full
        // page), and the caller is a SwiftUI view on the main actor — without this
        // hop the UI would freeze while the sheet shows "Reading the page…".
        // `Self.recognize` is static and touches only its arguments, so it is safe
        // off-main.
        let logger = log
        return await Task.detached(priority: .userInitiated) {
            Self.recognize(imageData: imageData, log: logger)
        }.value
    }

    private static func recognize(imageData: Data, log: Logger) -> [String] {
        let request = VNRecognizeTextRequest()
        // Accurate over fast: a one-shot import is worth the extra second, and a
        // misread ingredient costs the user a correction. Language correction helps
        // printed prose ("all-purpose" stays whole).
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]   // §2: English-only in v1

        let handler = VNImageRequestHandler(data: imageData, options: [:])
        do {
            try handler.perform([request])
        } catch {
            // A recognition failure degrades to "no lines" (the screen then offers
            // another photo); logged so a real failure is diagnosable, never a
            // crash. The error carries no user content.
            log.error("text recognition failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        return PhotoLineMerger.lines(from: boxes(from: request.results ?? []))
    }

    /// Vision observations → the Foundation-only boxes `PhotoLineMerger` groups.
    /// The top candidate is the line text; an observation with no candidate or no
    /// text is dropped rather than contributing an empty line.
    static func boxes(from observations: [VNRecognizedTextObservation]) -> [RecognizedTextBox] {
        observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            return RecognizedTextBox(text: text,
                                     minX: Double(box.minX),
                                     minY: Double(box.minY),
                                     width: Double(box.width),
                                     height: Double(box.height))
        }
    }
}
#endif
