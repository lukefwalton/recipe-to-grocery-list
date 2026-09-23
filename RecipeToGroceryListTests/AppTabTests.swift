import XCTest
@testable import RecipeToGroceryList

/// The tab shell's contract (spec §4.1): three tabs, List first and default, with
/// the titles and symbols the capture script and the empty-state deep links rely on.
/// Same altitude as the workout app's `AppTab` order test.
final class AppTabTests: XCTestCase {

    func testOrderIsListRecipesAdd() {
        XCTAssertEqual(AppTab.allCases, [.list, .recipes, .add])
    }

    func testListIsFirstAndIsTheDefaultTab() {
        XCTAssertEqual(AppTab.allCases.first, .list, "§4.1: List is the default tab")
        XCTAssertEqual(AppTab.list.rawValue, 0)
    }

    func testTitles() {
        XCTAssertEqual(AppTab.allCases.map(\.title), ["List", "Recipes", "Add"])
    }

    func testIconsAreNonEmptyAndDistinct() {
        let icons = AppTab.allCases.map(\.icon)
        for icon in icons {
            XCTAssertFalse(icon.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        XCTAssertEqual(Set(icons).count, icons.count, "each tab needs its own symbol")
    }

    func testIdentityIsTheRawValue() {
        for tab in AppTab.allCases {
            XCTAssertEqual(tab.id, tab.rawValue)
        }
    }

    func testPendingImportEquality() {
        let url = URL(string: "https://example.com/soup")!
        XCTAssertEqual(PendingImport.url(url), .url(url))
        XCTAssertEqual(PendingImport.text("a"), .text("a"))
        XCTAssertNotEqual(PendingImport.text("https://example.com/soup"), .url(url))
    }
}

/// The in-app privacy screen must use the same words as `docs/privacy.md` and the
/// App Store label (spec §10). Pinning the sentences here means a copy edit in one
/// place fails a test until the other places follow.
final class PrivacyCopyTests: XCTestCase {

    func testSentencesAreExactlyTheDocumentedOnes() {
        XCTAssertEqual(PrivacyCopy.sentences, [
            "Your recipes, ingredients and list live in a database on this phone.",
            "When you give it a link, the app downloads that page, once, and nothing else.",
            "Photos are read on this phone and never stored.",
            "On devices with Apple Intelligence, the app may use Apple's on-device model to read ingredient lines. No cloud AI, ever.",
            "No account, no analytics, no crash reporter, no third-party code.",
        ])
    }

    func testTheFetchPolicySentenceIsPresentVerbatim() {
        // §5.1: the one network call "must be describable in one sentence in the privacy copy".
        XCTAssertTrue(PrivacyCopy.sentences.contains("When you give it a link, the app downloads that page, once, and nothing else."))
    }

    func testPolicyLinkIsHTTPSOnTheAuthorSite() {
        XCTAssertEqual(PrivacyCopy.policyURL.scheme, "https")
        XCTAssertEqual(PrivacyCopy.policyURL.host, "lukefwalton.com")
        XCTAssertEqual(PrivacyCopy.policyURL.path, "/recipe-to-grocery-list/privacy/")
    }

    func testEveryPointHasASymbol() {
        for point in PrivacyCopy.points {
            XCTAssertFalse(point.symbol.isEmpty, point.sentence)
        }
        XCTAssertEqual(Set(PrivacyCopy.points.map(\.id)).count, PrivacyCopy.points.count)
    }
}

/// The Acknowledgements screen names everything `NOTICE.md` lists for the shipped
/// binary (§10): both OFL faces, the CC0 seed, the design system, the re-implemented
/// algorithm and the build-time tool.
final class AcknowledgementTests: XCTestCase {

    func testEveryExpectedNoticeIsPresent() {
        let names = Acknowledgement.all.map(\.name)
        for expected in ["Fraunces", "Inter", "The ingredient list", "LFWDesignSystem", "Jaro–Winkler similarity", "XcodeGen"] {
            XCTAssertTrue(names.contains(expected), "missing acknowledgement for \(expected)")
        }
        XCTAssertEqual(Set(names).count, names.count, "names double as ids")
    }

    func testBundledTypefacesAreEachAcknowledgedUnderTheOFL() {
        for face in Theme.bundledTypefaces {
            let entry = Acknowledgement.all.first { $0.name == face.displayName }
            XCTAssertNotNil(entry, "\(face.displayName) is bundled and must be acknowledged")
            XCTAssertEqual(entry?.license, "SIL Open Font License 1.1")
        }
    }

    func testSeedIsPublicDomain() {
        XCTAssertEqual(Acknowledgement.all.first { $0.name == "The ingredient list" }?.license, "CC0")
    }
}
