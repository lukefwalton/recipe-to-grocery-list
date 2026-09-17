import Foundation

/// One recognized text box in Vision's normalized coordinate space: origin
/// bottom-left, every value in 0…1. Foundation-only so the merging rule can be
/// unit-tested without Vision.
struct RecognizedTextBox: Equatable, Sendable {
    let text: String
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double

    init(text: String, minX: Double, minY: Double, width: Double, height: Double) {
        self.text = text
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    /// Vertical centre. Comparing centres rather than `minY` is what makes a tall
    /// box ("½") and a short one ("cup flour") on the same physical line group
    /// together.
    var centerY: Double { minY + height / 2 }
}

/// Turns Vision's boxes into the lines the pipeline consumes (spec §5.3).
///
/// Vision returns one observation per detected text region, in no particular
/// order, with the origin at the bottom-left. Sorting by `minY` alone misorders
/// anything with sub-pixel jitter, and ignores that several boxes usually make up
/// one physical line ("2 cups" and "all-purpose flour" often arrive separately).
/// So: sort by vertical centre (top of the page first), then group boxes whose
/// centres sit within half a line-height of the running line centre, then read
/// each group left to right.
///
/// The line-height reference is the **median** box height, not the mean: one
/// oversized drop-cap or a chapter heading must not stretch the grouping band for
/// the whole page.
///
/// **Known limitation, accepted by the spec:** two columns of ingredients at the
/// same height merge into one line, because they genuinely are at the same
/// height and nothing in a normalized box tells us a gutter from a wide space.
/// The user fixes it in Confirm, and the screen says "works best on a single
/// column" before they take the photo. `PhotoLineMergerTests` asserts this
/// behaviour explicitly so it stays a decision rather than a surprise.
enum PhotoLineMerger {
    static func lines(from boxes: [RecognizedTextBox]) -> [String] {
        let usable = boxes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return [] }

        let band = medianHeight(of: usable) / 2
        let sorted = usable.sorted { a, b in
            if a.centerY != b.centerY { return a.centerY > b.centerY }   // higher on the page first
            return a.minX < b.minX
        }

        var groups: [[RecognizedTextBox]] = []
        var current: [RecognizedTextBox] = []
        var currentCenter = 0.0
        for box in sorted {
            if current.isEmpty {
                current = [box]
                currentCenter = box.centerY
                continue
            }
            if abs(box.centerY - currentCenter) <= band {
                current.append(box)
                // Running mean, so a line's centre follows its boxes rather than
                // being pinned to whichever one happened to come first.
                currentCenter = current.reduce(0.0) { $0 + $1.centerY } / Double(current.count)
            } else {
                groups.append(current)
                current = [box]
                currentCenter = box.centerY
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            let line = group
                .sorted { $0.minX < $1.minX }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let collapsed = line.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
    }

    /// Median height of the boxes; 0 for an empty input (the caller guards).
    static func medianHeight(of boxes: [RecognizedTextBox]) -> Double {
        guard !boxes.isEmpty else { return 0 }
        let heights = boxes.map(\.height).sorted()
        let middle = heights.count / 2
        if heights.count % 2 == 1 { return heights[middle] }
        return (heights[middle - 1] + heights[middle]) / 2
    }
}
