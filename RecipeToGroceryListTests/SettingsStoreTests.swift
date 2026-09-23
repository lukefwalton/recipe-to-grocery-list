import XCTest
import LFWDesignSystem
@testable import RecipeToGroceryList

/// `SettingsStore` on a throwaway `UserDefaults` suite (the word app's
/// `SharedStoreTests` pattern): defaults, round trips through a second instance, the
/// key names other tooling depends on, and the sanitizer that keeps an unbundled
/// typeface from ever being presented.
final class SettingsStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SettingsStore!

    override func setUpWithError() throws {
        suiteName = "rtg-settings-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
    }

    // MARK: - Defaults

    func testFreshStoreHasTheFamilyDefaultTheme() {
        XCTAssertEqual(store.theme, LFWThemeConfig.default)
        XCTAssertEqual(store.theme.typeface, .fraunces)
        XCTAssertEqual(store.theme.palette, .forest, "§4.2: Forest is the default palette")
        XCTAssertEqual(store.theme.accentHueShift, 0)
    }

    func testFreshStoreHasNotCompletedOnboarding() {
        XCTAssertFalse(store.onboardingComplete)
    }

    func testBundledTypefacesAreExactlyFrauncesAndInter() {
        XCTAssertEqual(Theme.bundledTypefaces, [.fraunces, .inter])
    }

    // MARK: - Round trips

    func testThemeRoundTripsThroughASecondInstance() {
        let chosen = LFWThemeConfig(typeface: .inter, palette: .deepSea, accentHueShift: 35)
        store.theme = chosen
        XCTAssertEqual(store.theme, chosen)
        XCTAssertEqual(SettingsStore(defaults: defaults).theme, chosen, "the value lives in the defaults, not the instance")
    }

    func testThemeIsStoredAsJSONUnderTheThemeConfigKey() throws {
        store.theme = LFWThemeConfig(typeface: .fraunces, palette: .paper, accentHueShift: -20)
        let data = try XCTUnwrap(defaults.data(forKey: "themeConfig"), "key shared with the word app's SharedStore")
        let decoded = try JSONDecoder().decode(LFWThemeConfig.self, from: data)
        XCTAssertEqual(decoded.palette, .paper)
        XCTAssertEqual(decoded.accentHueShift, -20)
    }

    func testOnboardingFlagRoundTripsUnderItsKey() {
        store.onboardingComplete = true
        XCTAssertTrue(store.onboardingComplete)
        XCTAssertTrue(defaults.bool(forKey: "onboardingComplete"))
        XCTAssertTrue(SettingsStore(defaults: defaults).onboardingComplete)

        store.onboardingComplete = false
        XCTAssertFalse(SettingsStore(defaults: defaults).onboardingComplete)
    }

    // MARK: - Sanitizer (docs/learnings/001: never offer a face that renders as a fallback)

    func testStoredUnbundledTypefaceIsPresentedAsFraunces() throws {
        // A blob the word app's store would happily write: a face this app does not bundle.
        let json = #"{"typeface":"literata","palette":"dusk","accentHueShift":10}"#
        defaults.set(Data(json.utf8), forKey: "themeConfig")

        let theme = store.theme
        XCTAssertEqual(theme.typeface, .fraunces, "Literata is not bundled here; present the display default")
        XCTAssertEqual(theme.palette, .dusk, "only the typeface is touched")
        XCTAssertEqual(theme.accentHueShift, 10)
    }

    func testUnbundledTypefaceIsNotWrittenEither() throws {
        store.theme = LFWThemeConfig(typeface: .recursive, palette: .grape, accentHueShift: 0)
        let data = try XCTUnwrap(defaults.data(forKey: "themeConfig"))
        let stored = try JSONDecoder().decode(LFWThemeConfig.self, from: data)
        XCTAssertEqual(stored.typeface, .fraunces, "the stored value is honest too")
        XCTAssertEqual(stored.palette, .grape)
    }

    func testSanitizerKeepsEveryBundledFace() {
        for face in Theme.bundledTypefaces {
            let config = LFWThemeConfig(typeface: face, palette: .sepia, accentHueShift: 5)
            XCTAssertEqual(SettingsStore.sanitized(config), config, "\(face.displayName) is bundled and must survive")
        }
    }

    func testSanitizerMapsEveryUnbundledFaceToFraunces() {
        for face in LFWTypeface.allCases where !Theme.bundledTypefaces.contains(face) {
            XCTAssertEqual(SettingsStore.sanitized(LFWThemeConfig(typeface: face)).typeface, .fraunces, face.displayName)
        }
    }

    func testUnknownRawValuesFallBackThroughTheDesignSystemsTolerantDecode() {
        let json = #"{"typeface":"comic-sans","palette":"neon","accentHueShift":0}"#
        defaults.set(Data(json.utf8), forKey: "themeConfig")
        XCTAssertEqual(store.theme, LFWThemeConfig.default)
    }

    func testCorruptThemeDataFallsBackToTheDefault() {
        defaults.set(Data("not json".utf8), forKey: "themeConfig")
        XCTAssertEqual(store.theme, LFWThemeConfig.default)
    }

    // MARK: - Reset

    func testResetClearsOnlyItsOwnKeys() {
        store.theme = LFWThemeConfig(typeface: .inter, palette: .dawn, accentHueShift: 0)
        store.onboardingComplete = true
        defaults.set("kept", forKey: "somebodyElsesKey")

        store.reset()

        XCTAssertEqual(store.theme, LFWThemeConfig.default)
        XCTAssertFalse(store.onboardingComplete)
        XCTAssertNil(defaults.data(forKey: "themeConfig"))
        XCTAssertNil(defaults.object(forKey: "onboardingComplete"))
        XCTAssertEqual(defaults.string(forKey: "somebodyElsesKey"), "kept")
    }
}
