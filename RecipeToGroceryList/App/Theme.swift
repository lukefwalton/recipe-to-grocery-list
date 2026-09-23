import SwiftUI
import UIKit
import LFWDesignSystem

/// App-side alias for the shared family palette. Every color here forwards to
/// `LFWDesignSystem.LFWColors` so this app stays in lockstep with the other apps in
/// the family (spec §4.2 "only `LFWColors` and palette tokens"); status is the
/// on-palette `success` / `warning` / `danger` trio, never a system `.red` /
/// `.green` / `.orange`. Shape copied from `WorkoutChatLog/App/Theme.swift` at
/// `workout-logger@5bffddfb80fc`, with the green-led brand order of
/// `lfwdesignsystem` 2.3.0.
///
/// Compiled into the app target only: the Share Extension's `sources:` are its own
/// folder plus `RecipeToGroceryList/Shared`, so it never sees this file or its
/// `import LFWDesignSystem` (the extension has no design system by contract).
enum Theme {
    static let forest = LFWColors.forest
    static let verdigris = LFWColors.verdigris
    static let deepSea = LFWColors.deepSea
    static let ocean = LFWColors.ocean
    static let gold = LFWColors.gold
    static let paper = LFWColors.paper
    static let ink = LFWColors.ink
    static let steel = LFWColors.steel
    static let mist = LFWColors.mist

    /// App-wide accent (green leads the brand).
    static let tint = LFWColors.tint

    /// The Confirm screen's "highlighted" dot is `warning`, a refused alias is
    /// `danger`, a landed save is `success` (§4.2).
    static let success = LFWColors.success
    static let warning = LFWColors.warning
    static let danger = LFWColors.danger

    /// The typefaces this app actually bundles (`Resources/Fonts/Fraunces.ttf`,
    /// `Inter.ttf`). `LFWThemeConfig` knows seven, because the word app bundles all
    /// seven; here the Settings picker offers only these two, because a face that
    /// isn't bundled would silently render as New York / SF Rounded and a picker
    /// that lies is worse than a shorter picker (`docs/learnings/001`). The line is
    /// the source of truth for `scripts/check_fonts_sync.sh` (which greps it and
    /// cross-checks `Info.plist` `UIAppFonts` and `scripts/fetch_fonts.sh`) — keep
    /// its exact shape.
    static let bundledTypefaces: [LFWTypeface] = [.fraunces, .inter]

    /// The face every chrome role is set in (rows, quantities, units, buttons,
    /// numerals — §4.2 "numerals are always Inter"). Fixed, not the user's pick:
    /// the theme's `typeface` is the *display* face only.
    static let chromeTypeface: LFWTypeface = .inter

    // MARK: - Type by role (§4.2)

    /// The one display moment per screen — a recipe title, an ingredient heading, an
    /// empty-state title — in the theme's display face (Fraunces by default).
    static func displayFont(_ theme: LFWThemeConfig, size: CGFloat? = nil) -> Font {
        LFWTypography.font(.uiTitle, typeface: theme.typeface, size: size)
    }

    /// Everything else: rows, numbers, buttons, chrome. Always `chromeTypeface`.
    static func bodyFont(size: CGFloat? = nil) -> Font {
        LFWTypography.font(.uiBody, typeface: chromeTypeface, size: size)
    }
}

// MARK: - Themed chrome
//
// Ported verbatim from `WordOfTheDay/Features/Components/ThemedScreen.swift` at
// `a-new-word-every-day@e829bcc9c0dc` (spec §4.2 "the word app is the visual
// reference; reuse it, do not restyle"). Only the doc comments changed.

/// Shared chrome for in-app screens: themed gradient backdrop + navigation styling.
/// Every screen except onboarding (which sits on `LFWOnboardingBackground` by spec)
/// renders inside one of these, so no screen is ever a bare system background.
struct ThemedScreen<Content: View>: View {
    let theme: LFWThemeConfig
    var animateBackground: Bool = false
    @ViewBuilder var content: () -> Content

    private var palette: LFWPaletteColors { theme.colors }

    var body: some View {
        ZStack {
            LFWThemedBackground(config: theme, animated: animateBackground)
            content()
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(theme.palette.isDark ? .dark : .light, for: .navigationBar)
    }
}

/// Theme-aware primary/secondary pills for the compact, in-row and secondary
/// actions (Confirm's Use / Create / Same as… / Keep as text, the List's "Done
/// shopping"). Primary CTAs — the Add screen's Link / Paste / Photo entries and
/// Confirm's Save — stay on `LFWCTAButtonStyle` per SPEC §4.1; this style exists
/// because the outlined LFW pill draws `paper` text on the light palettes and is
/// too tall to sit three-up in a list row.
struct ThemedCTAButtonStyle: ButtonStyle {
    let palette: LFWPaletteColors
    var filled: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(filled ? palette.backgroundTop : palette.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: LFWRadius.card, style: .continuous)
                    .fill(filled ? palette.primaryText : palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LFWRadius.card, style: .continuous)
                    .strokeBorder(
                        filled ? Color.clear : palette.primaryText.opacity(0.35),
                        lineWidth: 1
                    )
            )
            .shadow(color: filled ? .black.opacity(0.12) : .clear, radius: 8, y: 4)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ThemedCTAButtonStyle {
    static func themedCTA(palette: LFWPaletteColors, filled: Bool = true) -> ThemedCTAButtonStyle {
        ThemedCTAButtonStyle(palette: palette, filled: filled)
    }
}

/// Applies themed list styling over the gradient background (List, Recipes).
struct ThemedListChrome: ViewModifier {
    let palette: LFWPaletteColors

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .listStyle(.plain)
            .listRowBackground(
                RoundedRectangle(cornerRadius: LFWRadius.surface, style: .continuous)
                    .fill(palette.backgroundBottom.opacity(0.72))
                    .padding(.vertical, 2)
            )
            .listRowSeparatorTint(palette.primaryText.opacity(0.12))
    }
}

/// Applies themed form styling over the gradient background (Settings, Confirm).
struct ThemedFormChrome: ViewModifier {
    let palette: LFWPaletteColors

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: LFWRadius.surface, style: .continuous)
                    .fill(palette.backgroundBottom.opacity(0.72))
            )
            .listRowSeparatorTint(palette.primaryText.opacity(0.10))
    }
}

enum TabBarAppearance {
    /// Match the tab bar to the active palette. UIKit appearance proxies are the
    /// only way to recolor a SwiftUI `TabView`'s bar, hence the `import UIKit`.
    static func apply(theme: LFWThemeConfig) {
        let colors = theme.colors
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = UIColor(colors.backgroundTop.opacity(0.92))
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor(colors.secondaryText)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(colors.secondaryText)
        ]
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(colors.accent)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor(colors.accent)
        ]
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}
