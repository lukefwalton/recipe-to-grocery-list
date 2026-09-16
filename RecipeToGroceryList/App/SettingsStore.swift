import Foundation
import LFWDesignSystem

/// The app's mutable non-database state: the theme and the first-run flag. It is
/// tiny — one JSON blob and one Bool — so plain `UserDefaults` beats a table here,
/// and it takes its `UserDefaults` so tests use a throwaway suite (spec §3 "keep
/// mutable non-DB state tiny and injectable"). Shape copied from
/// `WordOfTheDay/Shared/SharedStore.swift` at `a-new-word-every-day@e829bcc9c0dc`,
/// minus the App Group suite: nothing here is read by another process (the Share
/// Extension only writes the inbox file), so `.standard` is the production store.
///
/// Nothing here ever leaves the device. No identifiers, no analytics, no network.
final class SettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The production store. Private sandbox defaults — see the type comment.
    static let shared = SettingsStore(defaults: .standard)

    /// Keys are the word app's, so the theme blob has the same shape in both apps.
    enum Key {
        static let theme = "themeConfig"
        static let onboarding = "onboardingComplete"
    }

    // MARK: Theme

    /// The user's theme. Stored JSON-encoded; `LFWThemeConfig`'s tolerant decoder
    /// already turns an unknown palette/typeface raw value into the default instead
    /// of failing the whole blob. On top of that, `sanitized` maps a *known but
    /// unbundled* face (say Literata, from a blob the word app's shape would accept)
    /// to Fraunces, so the app never presents a face that would render as a system
    /// fallback (`docs/learnings/001`, "a picker that lies is worse than a shorter
    /// picker"). Applied on read AND write so the stored value is honest too.
    var theme: LFWThemeConfig {
        get {
            guard let data = defaults.data(forKey: Key.theme),
                  let config = try? JSONDecoder().decode(LFWThemeConfig.self, from: data)
            else { return .default }
            return Self.sanitized(config)
        }
        set {
            if let data = try? JSONEncoder().encode(Self.sanitized(newValue)) {
                defaults.set(data, forKey: Key.theme)
            }
        }
    }

    /// A theme whose typeface is one this app bundles. Any other face becomes
    /// `.fraunces` (the display default); palette and accent nudge are untouched.
    static func sanitized(_ config: LFWThemeConfig) -> LFWThemeConfig {
        guard !Theme.bundledTypefaces.contains(config.typeface) else { return config }
        var fixed = config
        fixed.typeface = .fraunces
        return fixed
    }

    // MARK: Onboarding

    var onboardingComplete: Bool {
        get { defaults.bool(forKey: Key.onboarding) }
        set { defaults.set(newValue, forKey: Key.onboarding) }
    }

    // MARK: Reset

    /// Forget everything this store owns — the UI-test `-UITestResetOnboarding`
    /// path. Removes only our own keys rather than the whole persistent domain, so a
    /// test suite injected here never wipes unrelated defaults.
    func reset() {
        defaults.removeObject(forKey: Key.theme)
        defaults.removeObject(forKey: Key.onboarding)
    }
}
