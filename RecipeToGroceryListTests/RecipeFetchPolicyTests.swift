import XCTest
@testable import RecipeToGroceryList

/// The app's entire network policy (spec §5.1), which is also the promise the
/// privacy screen makes in one sentence: *"When you give it a link, the app
/// downloads that page, once, and nothing else."* Each clause of that sentence is
/// a rule in `RecipeFetchPolicy`, and each rule is pinned here — the policy is
/// pure precisely so it can be tested without a server. `RecipeFetcher` itself is
/// the thin plumbing that obeys these and is verified on device.
final class RecipeFetchPolicyTests: XCTestCase {

    // MARK: - validate

    func testHTTPSURLIsAccepted() throws {
        let url = try XCTUnwrap(try? RecipeFetchPolicy.validate("https://example.com/recipes/soup").get())
        XCTAssertEqual(url.absoluteString, "https://example.com/recipes/soup")
    }

    func testSurroundingWhitespaceIsTrimmed() throws {
        let url = try XCTUnwrap(try? RecipeFetchPolicy.validate("  https://example.com/x \n").get())
        XCTAssertEqual(url.absoluteString, "https://example.com/x")
    }

    /// `http` is refused rather than silently upgraded: guessing at a scheme is
    /// guessing at where the request goes.
    func testPlainHTTPIsRefusedWithItsOwnMessage() {
        XCTAssertEqual(failure(of: "http://example.com/x"), .notHTTPS)
        XCTAssertEqual(RecipeFetchError.notHTTPS.message, "Only https links are supported.")
    }

    func testSchemeComparisonIsCaseInsensitive() throws {
        XCTAssertNotNil(try? RecipeFetchPolicy.validate("HTTPS://example.com/x").get())
        XCTAssertEqual(failure(of: "HTTP://example.com/x"), .notHTTPS)
    }

    func testNonWebAndMalformedInputIsRefused() {
        XCTAssertEqual(failure(of: ""), .invalidURL)
        XCTAssertEqual(failure(of: "   "), .invalidURL)
        XCTAssertEqual(failure(of: "not a url"), .invalidURL)
        XCTAssertEqual(failure(of: "example.com/recipes"), .invalidURL, "no scheme is not a web address")
        XCTAssertEqual(failure(of: "file:///etc/passwd"), .notHTTPS)
        XCTAssertEqual(failure(of: "https://"), .invalidURL, "a scheme with no host is not a page")
    }

    // MARK: - redirects

    func testRedirectsAreFollowedUpToTheCap() {
        let target = URL(string: "https://example.com/final")
        for hop in 1...RecipeFetchPolicy.maxRedirects {
            XCTAssertNil(RecipeFetchPolicy.redirectError(to: target, redirectCount: hop),
                         "hop \(hop) is within the cap of \(RecipeFetchPolicy.maxRedirects)")
        }
        XCTAssertEqual(RecipeFetchPolicy.redirectError(to: target,
                                                       redirectCount: RecipeFetchPolicy.maxRedirects + 1),
                       .tooManyRedirects)
    }

    /// "same scheme" from the spec: a redirect off https ends the fetch instead of
    /// quietly downgrading it.
    func testRedirectToANonHTTPSTargetStopsTheFetch() {
        XCTAssertEqual(RecipeFetchPolicy.redirectError(to: URL(string: "http://example.com/x"), redirectCount: 1),
                       .redirectNotHTTPS)
        XCTAssertEqual(RecipeFetchPolicy.redirectError(to: nil, redirectCount: 1), .invalidURL)
    }

    // MARK: - session configuration

    func testSessionCarriesNoCookiesNoCacheAndTheStatedTimeouts() {
        let configuration = RecipeFetchPolicy.makeSessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage, "no cookies are stored")
        XCTAssertFalse(configuration.httpShouldSetCookies, "and none are sent")
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCache, "the page is read once and discarded")
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 15)
        XCTAssertFalse(configuration.waitsForConnectivity, "no queued request that fires later")
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
    }

    func testSessionSendsOnlyTheTwoDeclaredHeaders() throws {
        let headers = try XCTUnwrap(RecipeFetchPolicy.makeSessionConfiguration().httpAdditionalHeaders)
        XCTAssertEqual(headers["Accept"] as? String, "text/html")
        XCTAssertEqual(headers["User-Agent"] as? String, RecipeFetchPolicy.userAgent)
        XCTAssertEqual(headers.count, 2)
    }

    /// A plain identifier, not a browser impersonation — the privacy posture is
    /// visible from the other end of the connection too.
    func testUserAgentNamesTheAppAndNotABrowser() {
        let agent = RecipeFetchPolicy.userAgent
        XCTAssertTrue(agent.hasPrefix("RecipeToGroceryList/"))
        XCTAssertFalse(agent.lowercased().contains("mozilla"))
        XCTAssertFalse(agent.lowercased().contains("safari"))
    }

    func testRequestIsAPlainGETOfTheExactURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/recipes/soup?x=1"))
        let request = RecipeFetchPolicy.makeRequest(url)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url, url, "the exact address the user gave, unrewritten")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testLimitsMatchTheSpec() {
        XCTAssertEqual(RecipeFetchPolicy.maxRedirects, 5)
        XCTAssertEqual(RecipeFetchPolicy.timeout, 15)
        XCTAssertEqual(RecipeFetchPolicy.maxBytes, 3_000_000)
        XCTAssertEqual(RecipeFetchPolicy.accept, "text/html")
    }

    // MARK: - messages

    /// Every failure is shown to the user, so every case needs real words.
    func testEveryErrorHasAUsableMessage() {
        let errors: [RecipeFetchError] = [
            .invalidURL, .notHTTPS, .tooManyRedirects, .redirectNotHTTPS,
            .responseTooLarge, .badStatus(500), .timedOut, .network("Offline."),
        ]
        for error in errors {
            XCTAssertFalse(error.message.isEmpty, "\(error) has no message")
            XCTAssertTrue(error.message.hasSuffix("."), "\(error)'s message is not a sentence")
        }
        XCTAssertTrue(RecipeFetchError.badStatus(404).message.contains("404"))
    }

    // MARK: - Helper

    private func failure(of text: String) -> RecipeFetchError? {
        switch RecipeFetchPolicy.validate(text) {
        case .failure(let error): return error
        case .success: return nil
        }
    }
}
