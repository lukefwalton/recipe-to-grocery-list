import SwiftUI
import LFWDesignSystem

/// The in-app privacy screen (spec §10). Its sentences are the same words as
/// `docs/privacy.md` and the App Store label copy, on purpose: one description of
/// the one network request, everywhere. Kept as data (`PrivacyCopy`) so a test can
/// pin the exact wording and the doc can be diffed against it.
struct PrivacyView: View {
    @EnvironmentObject private var model: AppModel

    private var palette: LFWPaletteColors { model.theme.colors }

    var body: some View {
        ThemedScreen(theme: model.theme) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Nothing leaves your phone.")
                        .font(Theme.displayFont(model.theme, size: 28))
                        .foregroundStyle(palette.primaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(PrivacyCopy.points) { point in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: point.symbol)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(palette.accent)
                                    .frame(width: 28)
                                    .accessibilityHidden(true)
                                Text(point.sentence)
                                    .font(Theme.bodyFont(size: 16))
                                    .foregroundStyle(palette.primaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: LFWRadius.surface, style: .continuous)
                            .fill(palette.surface)
                    )

                    Link(destination: PrivacyCopy.policyURL) {
                        Label("Full privacy policy", systemImage: "arrow.up.right.square")
                            .font(Theme.bodyFont(size: 16))
                    }
                    .tint(palette.accent)
                }
                .padding(24)
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The privacy promise, sentence by sentence. These strings must stay identical to
/// the ones in `docs/privacy.md` (§10: "the same words"); `PrivacyCopyTests` pins them.
enum PrivacyCopy {
    struct Point: Identifiable {
        let symbol: String
        let sentence: String
        var id: String { sentence }
    }

    static let points: [Point] = [
        Point(symbol: "internaldrive",
              sentence: "Your recipes, ingredients and list live in a database on this phone."),
        Point(symbol: "link",
              sentence: "When you give it a link, the app downloads that page, once, and nothing else."),
        Point(symbol: "camera",
              sentence: "Photos are read on this phone and never stored."),
        Point(symbol: "cpu",
              sentence: "On devices with Apple Intelligence, the app may use Apple's on-device model to read ingredient lines. No cloud AI, ever."),
        Point(symbol: "hand.raised",
              sentence: "No account, no analytics, no crash reporter, no third-party code."),
    ]

    static var sentences: [String] { points.map(\.sentence) }

    static let policyURL = URL(string: "https://lukefwalton.com/recipe-to-grocery-list/privacy/")!
}
