import SwiftUI
import LFWDesignSystem

/// Theme picker, the two confirmed list actions, and an honest About section (spec
/// §4.1 "Settings"). Presented from the List screen's gear as a sheet, hence the
/// Done button. Shape copied from `WordOfTheDay/Features/Settings/SettingsView.swift`
/// at `a-new-word-every-day@e829bcc9c0dc`: `Form` inside `NavigationStack` inside
/// `ThemedScreen`, `ThemedFormChrome` over the gradient. Every store write goes
/// through the typed `RecipeStore` API and is followed by `model.didWrite()`.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingClearChecked = false
    @State private var confirmingDeselectAll = false
    @State private var ingredientCount: Int = 0
    @State private var actionError: String?

    private var typeface: LFWTypeface { model.theme.typeface }
    private var palette: LFWPaletteColors { model.theme.colors }

    var body: some View {
        ThemedScreen(theme: model.theme) {
            NavigationStack {
                Form {
                    typefaceSection
                    colorSection
                    listSection
                    aboutSection
                }
                .environment(\.defaultMinListRowHeight, 1)
                .modifier(ThemedFormChrome(palette: palette))
                .foregroundStyle(palette.primaryText)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .tint(palette.accent)
                    }
                }
            }
        }
        .onAppear { reloadCounts() }
        .onChange(of: model.changeToken) { _, _ in reloadCounts() }
        .alert("Couldn't update the list",
               isPresented: Binding(get: { actionError != nil },
                                    set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Typeface

    /// Only the faces this app bundles (`Theme.bundledTypefaces`), sampled on a
    /// real ingredient heading — the role the pick actually changes.
    private var typefaceSection: some View {
        Section {
            ForEach(Theme.bundledTypefaces) { face in
                Button {
                    var theme = model.theme
                    theme.typeface = face
                    model.setTheme(theme)
                    LFWHaptics.selection()
                } label: {
                    HStack {
                        Text("Vegetable broth")
                            .font(LFWTypography.font(.uiTitle, typeface: face, size: 22))
                            .foregroundStyle(palette.primaryText)
                        Spacer()
                        Text(face.displayName)
                            .foregroundStyle(palette.secondaryText)
                        if face == typeface {
                            Image(systemName: "checkmark").foregroundStyle(palette.accent)
                        }
                    }
                }
                .tint(palette.accent)
                .accessibilityLabel("\(face.displayName)\(face == typeface ? ", selected" : "")")
            }
        } header: {
            Text("Typeface")
        } footer: {
            Text("Recipe titles and ingredient headings use this face. Rows, numbers and buttons are always Inter.")
                .foregroundStyle(palette.secondaryText)
        }
    }

    // MARK: Color

    private var colorSection: some View {
        Section("Color") {
            ForEach(LFWPalette.allCases) { paletteOption in
                Button {
                    var theme = model.theme
                    theme.palette = paletteOption
                    model.setTheme(theme)
                    LFWHaptics.selection()
                } label: {
                    HStack(spacing: 12) {
                        swatch(paletteOption)
                        Text(paletteOption.displayName).foregroundStyle(palette.primaryText)
                        Spacer()
                        if paletteOption == model.theme.palette {
                            Image(systemName: "checkmark").foregroundStyle(palette.accent)
                        }
                    }
                }
                .tint(palette.accent)
                .accessibilityLabel("\(paletteOption.displayName)\(paletteOption == model.theme.palette ? ", selected" : "")")
            }

            VStack(alignment: .leading) {
                Text("Accent hue")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Slider(
                    value: Binding(
                        get: { model.theme.accentHueShift },
                        set: { newValue in
                            var theme = model.theme
                            theme.accentHueShift = newValue
                            model.setTheme(theme)
                        }
                    ),
                    in: -180...180, step: 5
                )
                .tint(palette.accent)
                .accessibilityLabel("Accent hue")
            }
        }
    }

    private func swatch(_ paletteOption: LFWPalette) -> some View {
        let c = paletteOption.colors
        return RoundedRectangle(cornerRadius: LFWRadius.chip, style: .continuous)
            .fill(LinearGradient(colors: [c.backgroundTop, c.backgroundBottom],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 44, height: 28)
            .overlay(Circle().fill(c.accent).frame(width: 10, height: 10).padding(5),
                     alignment: .bottomTrailing)
            .overlay(RoundedRectangle(cornerRadius: LFWRadius.chip)
                .strokeBorder(.black.opacity(0.1)))
            .accessibilityHidden(true)
    }

    // MARK: List (§9, both confirmed)

    private var listSection: some View {
        Section {
            Button {
                confirmingClearChecked = true
            } label: {
                Label("Clear checked", systemImage: "checkmark.circle.badge.xmark")
                    .foregroundStyle(palette.primaryText)
            }
            .tint(palette.accent)
            .confirmationDialog("Clear checked?", isPresented: $confirmingClearChecked, titleVisibility: .visible) {
                Button("Clear checked", role: .destructive) { clearChecked() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Unchecks every ingredient and removes checked manual items. Your recipes stay selected.")
            }

            Button {
                confirmingDeselectAll = true
            } label: {
                Label("Deselect all recipes", systemImage: "book.closed")
                    .foregroundStyle(palette.primaryText)
            }
            .tint(palette.accent)
            .confirmationDialog("Deselect all recipes?", isPresented: $confirmingDeselectAll, titleVisibility: .visible) {
                Button("Deselect all", role: .destructive) { deselectAllRecipes() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Turns off “cooking this” for every recipe. The list empties; nothing is deleted.")
            }
        } header: {
            Text("List")
        } footer: {
            Text("“Done shopping” on the List does both at once.")
                .foregroundStyle(palette.secondaryText)
        }
    }

    // The store's writes are `@MainActor`; the helpers say so explicitly (the workout
    // app's `SettingsView` does the same) rather than relying on the SDK's `View`
    // isolation, which differs between Xcode 15 and 16.
    @MainActor
    private func clearChecked() {
        do {
            try model.store.clearChecked()
            model.didWrite()
            LFWHaptics.selection()
        } catch {
            actionError = String(describing: error)
            LFWHaptics.failure()
        }
    }

    @MainActor
    private func deselectAllRecipes() {
        do {
            try model.store.deselectAllRecipes()
            model.didWrite()
            LFWHaptics.selection()
        } catch {
            actionError = String(describing: error)
            LFWHaptics.failure()
        }
    }

    // MARK: About

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    /// §7.6: say plainly whether the on-device model is in play on this device.
    private var onDeviceAIText: String {
        model.onDeviceAIAvailable ? "On-device AI: available" : RecipeParserFactory.unavailableCopy
    }

    private var aboutSection: some View {
        Section("About") {
            valueRow("Version", appVersion)
            valueRow("Seed", "\(IngredientSeed.version) · \(ingredientCount) ingredients")
            Label(onDeviceAIText, systemImage: "cpu")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
            NavigationLink {
                PrivacyView()
            } label: {
                Label("Privacy", systemImage: "hand.raised")
            }
            NavigationLink {
                AcknowledgementsView()
            } label: {
                Label("Acknowledgements", systemImage: "text.book.closed")
            }
        }
    }

    /// A label / value row. Values carry numerals, so they are set in the chrome face
    /// (§4.2 "numerals are always Inter").
    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(Theme.bodyFont(size: 16))
                .foregroundStyle(palette.secondaryText)
        }
    }

    @MainActor
    private func reloadCounts() {
        ingredientCount = (try? model.store.ingredientCount()) ?? 0
    }
}
