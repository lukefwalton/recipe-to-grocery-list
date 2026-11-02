import Foundation

/// The seam between the photo screen and the on-device text recognizer (spec
/// §5.3). Foundation only — **no `Vision` symbol appears here** — so this
/// protocol, the photo screen and the tests compile and run whether or not
/// Vision is available. The gated `VisionTextRecognizer` is the real
/// implementation; tests drive a fake.
///
/// Shape ported from `WorkoutChatLog/Vision/TextRecognizing.swift` at
/// `workout-logger@5bffddfb80fc`. The photo screen reviews the recognized lines
/// against the picture before they are parsed: a whole recipe page is not an
/// ingredient list, and Confirm never sees the image.
///
/// `imageData` is encoded image bytes (JPEG/PNG/HEIC): keeping the boundary at
/// `Data` means no common code needs `UIImage`, `CGImage` or a Vision type.
protocol TextRecognizing: Sendable {
    /// Lines in natural reading order, top to bottom. `[]` when nothing is found
    /// or recognition is unavailable — never throws into the UI; an empty result
    /// is the honest signal, and the screen offers another photo.
    func recognizeLines(in imageData: Data) async -> [String]

    /// The same lines, with the union box of each physical line when the
    /// recognizer has one. The default builds frameless lines from `recognizeLines`.
    func recognizePage(in imageData: Data) async -> [RecognizedLine]
}

extension TextRecognizing {
    func recognizePage(in imageData: Data) async -> [RecognizedLine] {
        let lines = await recognizeLines(in: imageData)
        return lines.map { RecognizedLine(text: $0, minX: 0, minY: 0, width: 0, height: 0) }
    }
}

/// The stand-in when Vision isn't compiled in (Linux/CI) or is unavailable: it
/// recognizes nothing, so the photo flow degrades to "couldn't read that photo"
/// rather than crashing.
struct NoopTextRecognizer: TextRecognizing {
    func recognizeLines(in imageData: Data) async -> [String] { [] }
}

/// Picks the real recognizer when the SDK is present, the no-op otherwise. The
/// `#if` is the only place the two worlds meet; callers just get a `TextRecognizing`.
enum TextRecognizerFactory {
    static func make() -> TextRecognizing {
        #if canImport(Vision)
        return VisionTextRecognizer()
        #else
        return NoopTextRecognizer()
        #endif
    }
}
