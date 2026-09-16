import SwiftUI
import LFWDesignSystem

/// Who and what the app stands on (spec §10, `NOTICE.md`). Zero third-party code
/// ships in the binary; what does ship is two OFL typefaces and a public-domain
/// ingredient list, and the two build-time / re-implemented items are named so the
/// notice is complete rather than convenient. The full OFL text travels with the
/// fonts as `OFL.txt` and is shown here when the bundle has it.
struct AcknowledgementsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingLicense = false

    private var palette: LFWPaletteColors { model.theme.colors }

    var body: some View {
        ThemedScreen(theme: model.theme) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Made with")
                        .font(Theme.displayFont(model.theme, size: 28))
                        .foregroundStyle(palette.primaryText)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Acknowledgement.all.enumerated()), id: \.element.id) { position, entry in
                            entryRow(entry)
                            if position < Acknowledgement.all.count - 1 {
                                Divider().overlay(palette.primaryText.opacity(0.12))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: LFWRadius.surface, style: .continuous)
                            .fill(palette.surface)
                    )

                    if let license = Acknowledgement.openFontLicense {
                        DisclosureGroup(isExpanded: $showingLicense) {
                            Text(license)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                                .textSelection(.enabled)
                                .padding(.top, 8)
                        } label: {
                            Text("SIL Open Font License 1.1 (OFL.txt)")
                                .font(Theme.bodyFont(size: 15))
                                .foregroundStyle(palette.primaryText)
                        }
                        .tint(palette.accent)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func entryRow(_ entry: Acknowledgement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name)
                    .font(Theme.bodyFont(size: 16))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Text(entry.license)
                    .font(Theme.bodyFont(size: 13))
                    .foregroundStyle(palette.accent)
                    .multilineTextAlignment(.trailing)
            }
            Text(entry.detail)
                .font(Theme.bodyFont(size: 14))
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// One notice entry. Mirrors the reuse log in `NOTICE.md`; keep the two in step.
struct Acknowledgement: Identifiable, Equatable {
    let name: String
    let license: String
    let detail: String

    var id: String { name }

    static let all: [Acknowledgement] = [
        Acknowledgement(name: "Fraunces",
                        license: "SIL Open Font License 1.1",
                        detail: "The display face — recipe titles and ingredient headings. Bundled; the license text ships as OFL.txt."),
        Acknowledgement(name: "Inter",
                        license: "SIL Open Font License 1.1",
                        detail: "The chrome face — rows, quantities, units and buttons. Bundled; the license text ships as OFL.txt."),
        Acknowledgement(name: "The ingredient list",
                        license: "CC0",
                        detail: "The canonical ingredients, their store categories and their aliases were written for this app and dedicated to the public domain."),
        Acknowledgement(name: "LFWDesignSystem",
                        license: "Same author",
                        detail: "The family palette, type roles, onboarding kit and empty states, shared with the sibling apps and vendored here as a local Swift package."),
        Acknowledgement(name: "Jaro–Winkler similarity",
                        license: "Published algorithm",
                        detail: "The string metric behind fuzzy ingredient matching (Jaro 1989; Winkler 1990), re-implemented here from the published description. No code was copied."),
        Acknowledgement(name: "XcodeGen",
                        license: "MIT, build-time only",
                        detail: "Generates the Xcode project from project.yml on the developer's machine. Nothing from it is in the app."),
    ]

    /// The bundled `OFL.txt` (enumerated into the bundle root with the fonts), or
    /// nil before `scripts/fetch_fonts.sh` has run — the section then simply hides.
    static var openFontLicense: String? {
        guard let url = Bundle.main.url(forResource: "OFL", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
