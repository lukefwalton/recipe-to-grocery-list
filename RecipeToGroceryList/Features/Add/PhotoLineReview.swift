import SwiftUI
import LFWDesignSystem

#if canImport(UIKit)
import UIKit
#endif

/// The photo screen's ingredient check, shown on the picture before anything is
/// parsed. The proposal comes from `IngredientBlock`. Dragging the band selects
/// every non-heading line inside it; tapping a line puts it on or takes it off.
/// Headings stay captions either way — checking "Let's get started" cannot turn
/// it into a grocery row.
struct PhotoLineReview: View {
    let imageData: Data
    let lines: [RecognizedLine]
    @Binding var included: Set<Int>
    let palette: LFWPaletteColors
    let isParsing: Bool
    let onUse: () -> Void
    let onDifferentPhoto: () -> Void

    @State private var cropTop: CGFloat
    @State private var cropBottom: CGFloat

    init(imageData: Data,
         lines: [RecognizedLine],
         included: Binding<Set<Int>>,
         palette: LFWPaletteColors,
         isParsing: Bool,
         onUse: @escaping () -> Void,
         onDifferentPhoto: @escaping () -> Void) {
        self.imageData = imageData
        self.lines = lines
        _included = included
        self.palette = palette
        self.isParsing = isParsing
        self.onUse = onUse
        self.onDifferentPhoto = onDifferentPhoto
        let band = Self.initialBand(lines: lines, included: included.wrappedValue)
        _cropTop = State(initialValue: band.top)
        _cropBottom = State(initialValue: band.bottom)
    }

    private var showsCrop: Bool { lines.contains(where: \.hasFrame) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsCrop {
                crop
                Text("Drag the band to the ingredient list. Tap a line to leave it off.")
                    .font(Theme.bodyFont(size: 13))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Uncheck anything that isn't an ingredient. Unchecked lines stay off the list.")
                    .font(Theme.bodyFont(size: 13))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines.indices, id: \.self) { index in
                        lineRow(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(summary)
                .font(Theme.bodyFont(size: 13))
                .foregroundStyle(palette.secondaryText)

            Button(action: onUse) {
                if isParsing {
                    ProgressView()
                        .tint(LFWColors.deepSea)
                } else {
                    Text(useLabel)
                }
            }
            .buttonStyle(LFWCTAButtonStyle())
            .disabled(isParsing || included.isEmpty)
            .opacity(included.isEmpty ? 0.55 : 1)

            Button("Different photo", action: onDifferentPhoto)
                .buttonStyle(LFWCTAButtonStyle(filled: false))
                .disabled(isParsing)
        }
    }

    private var summary: String {
        let on = included.count
        let off = lines.count - on - lines.indices.filter { IngredientBlock.isStructuralHeading(lines[$0].text) }.count
        let onLabel = on == 1 ? "1 line on the list" : "\(on) lines on the list"
        let offLabel = off == 1 ? "1 left off" : "\(off) left off"
        return "\(onLabel) · \(offLabel)"
    }

    private var useLabel: String {
        if included.count == 1 { return "Use 1 ingredient" }
        return "Use \(included.count) ingredients"
    }

    @ViewBuilder
    private func lineRow(_ index: Int) -> some View {
        let text = lines[index].text
        if IngredientBlock.isStructuralHeading(text) {
            Text(text)
                .font(Theme.bodyFont(size: 13))
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
                .accessibilityLabel("Heading: \(text)")
        } else {
            let on = included.contains(index)
            Button {
                if on {
                    included.remove(index)
                } else {
                    included.insert(index)
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? palette.accent : palette.secondaryText)
                    Text(text)
                        .font(Theme.bodyFont(size: 16))
                        .foregroundStyle(on ? palette.primaryText : palette.secondaryText)
                        .strikethrough(!on)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(on ? "On the list: \(text)" : "Off the list: \(text)")
            .accessibilityHint("Toggles whether this line is an ingredient")
        }
    }

    // MARK: - Crop band

    @ViewBuilder
    private var crop: some View {
        #if canImport(UIKit)
        if let image = UIImage(data: imageData) {
            cropImage(image)
        }
        #endif
    }

    #if canImport(UIKit)
    private func cropImage(_ image: UIImage) -> some View {
        GeometryReader { geo in
            let rect = fittedRect(imageSize: image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                shade(in: geo.size, imageRect: rect)

                Rectangle()
                    .strokeBorder(palette.accent, lineWidth: 2)
                    .frame(width: rect.width, height: max(0, (cropBottom - cropTop) * rect.height))
                    .offset(x: rect.minX, y: rect.minY + cropTop * rect.height)
                    .allowsHitTesting(false)

                handle(edge: .top, imageRect: rect)
                handle(edge: .bottom, imageRect: rect)
            }
            .coordinateSpace(name: "crop")
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: LFWRadius.card, style: .continuous))
        .accessibilityLabel("Photo with the ingredient band")
    }

    private func shade(in bounds: CGSize, imageRect: CGRect) -> some View {
        let topHeight = cropTop * imageRect.height
        let bottomHeight = (1 - cropBottom) * imageRect.height
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.45)
                .frame(width: imageRect.width, height: max(0, topHeight))
                .offset(x: imageRect.minX, y: imageRect.minY)
            Color.black.opacity(0.45)
                .frame(width: imageRect.width, height: max(0, bottomHeight))
                .offset(x: imageRect.minX, y: imageRect.minY + cropBottom * imageRect.height)
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private enum Edge { case top, bottom }

    private func handle(edge: Edge, imageRect: CGRect) -> some View {
        let y = imageRect.minY + (edge == .top ? cropTop : cropBottom) * imageRect.height
        return Capsule()
            .fill(palette.accent)
            .frame(width: 48, height: 6)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
            .position(x: imageRect.midX, y: y)
            .gesture(drag(edge, imageRect: imageRect))
            .accessibilityLabel(edge == .top ? "Top of the ingredient band" : "Bottom of the ingredient band")
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 0.04 : -0.04
                if edge == .top {
                    cropTop = min(max(0, cropTop + step), cropBottom - 0.08)
                } else {
                    cropBottom = min(max(cropTop + 0.08, cropBottom + step), 1)
                }
                applyCrop()
            }
    }

    private func drag(_ edge: Edge, imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
            .onChanged { value in
                guard imageRect.height > 0 else { return }
                let fraction = (value.location.y - imageRect.minY) / imageRect.height
                let clamped = min(max(fraction, 0), 1)
                switch edge {
                case .top:
                    cropTop = min(clamped, cropBottom - 0.08)
                case .bottom:
                    cropBottom = max(clamped, cropTop + 0.08)
                }
                applyCrop()
            }
    }

    private func fittedRect(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }
    #endif

    /// Selects every non-heading line whose centre sits inside the band. Headings
    /// stay headings. A line without a frame is left as the reader toggled it.
    private func applyCrop() {
        var next = included.filter { index in
            guard lines.indices.contains(index) else { return false }
            return !lines[index].hasFrame
        }
        for (index, line) in lines.enumerated() where line.hasFrame && !IngredientBlock.isStructuralHeading(line.text) {
            let center = CGFloat(line.centerFromTop)
            if center >= cropTop && center <= cropBottom {
                next.insert(index)
            } else {
                next.remove(index)
            }
        }
        included = next
    }

    private static func initialBand(lines: [RecognizedLine], included: Set<Int>) -> (top: CGFloat, bottom: CGFloat) {
        let edges = included.compactMap { index -> (CGFloat, CGFloat)? in
            guard lines.indices.contains(index) else { return nil }
            let line = lines[index]
            guard line.hasFrame else { return nil }
            let top = CGFloat(1 - (line.minY + line.height))
            let bottom = CGFloat(1 - line.minY)
            return (top, bottom)
        }
        guard let top = edges.map(\.0).min(), let bottom = edges.map(\.1).max() else {
            return (0, 1)
        }
        return (max(0, top - 0.015), min(1, bottom + 0.015))
    }
}
