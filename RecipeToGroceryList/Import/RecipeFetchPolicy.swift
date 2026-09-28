import Foundation

/// Why a page fetch was refused or failed. Every case carries copy the Link
/// screen shows verbatim — the user is owed a reason, not a spinner that stops.
enum RecipeFetchError: Error, Equatable {
    case invalidURL
    case notHTTPS
    case tooManyRedirects
    case redirectNotHTTPS
    case responseTooLarge
    case badStatus(Int)
    case timedOut
    case network(String)

    var message: String {
        switch self {
        case .invalidURL:
            return "That doesn't look like a web address."
        case .notHTTPS:
            return "Only https links are supported."
        case .tooManyRedirects:
            return "That link redirected too many times."
        case .redirectNotHTTPS:
            return "That link redirected somewhere insecure, so the app stopped."
        case .responseTooLarge:
            return "That page is too big to read."
        case .badStatus(let code):
            return "The site answered with an error (\(code))."
        case .timedOut:
            return "The page took too long to answer."
        case .network(let detail):
            return "Couldn't reach that page. \(detail)"
        }
    }
}

/// One downloaded page: the address the download actually ended at (after any
/// redirects — what gets stored as `source_ref`) and its HTML.
struct FetchedPage: Equatable, Sendable {
    let finalURL: URL
    let html: String
}

/// The seam between the Link screen and the network, so a test or a preview can
/// stand in for the real fetch without a server.
protocol PageFetching: Sendable {
    func fetch(_ url: URL) async throws -> FetchedPage
}

/// The app's **entire network policy**, as code (spec §5.1). This is the one
/// kind of request the app ever makes, and the promise in `docs/privacy.md` and
/// the onboarding is a single sentence: *"When you give it a link, the app
/// downloads that page, once, and nothing else."* Every clause of that sentence
/// is a rule here, and every rule is unit-tested — the pure parts live in this
/// file precisely so they can be, while `RecipeFetcher` is the thin, device-
/// verified plumbing that obeys them.
enum RecipeFetchPolicy {
    /// At most five hops, and only to other `https` addresses.
    static let maxRedirects = 5
    /// Seconds, for both the request and the whole resource.
    static let timeout: TimeInterval = 15
    /// 3 MB. A recipe page that exceeds this is not a recipe page.
    static let maxBytes = 3_000_000
    static let accept = "text/html"
    /// A plain, honest identifier — no browser impersonation, no version fingerprint
    /// beyond the app's own.
    static let userAgent = "RecipeToGroceryList/1.0 (iPhone; +https://github.com/lukefwalton/recipe-to-grocery-list)"

    /// The address the user typed or shared, or why it is refused. `https` only
    /// (ATS default, no exceptions): plain `http` is refused with its own message
    /// rather than silently upgraded, because guessing at a scheme is guessing at
    /// where the request goes.
    static func validate(_ text: String) -> Result<URL, RecipeFetchError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme else {
            return .failure(.invalidURL)
        }
        guard scheme.lowercased() == "https" else { return .failure(.notHTTPS) }
        guard let host = url.host, !host.isEmpty else { return .failure(.invalidURL) }
        return .success(url)
    }

    /// Whether a redirect may be followed. nil = allowed. `redirectCount` is the
    /// number of hops already taken, so the first redirect arrives as 1.
    static func redirectError(to target: URL?, redirectCount: Int) -> RecipeFetchError? {
        guard redirectCount <= maxRedirects else { return .tooManyRedirects }
        guard let target, let scheme = target.scheme else { return .invalidURL }
        guard scheme.lowercased() == "https" else { return .redirectNotHTTPS }
        return nil
    }

    /// The session every fetch runs on: ephemeral, cookie-less, cache-less,
    /// one connection, fixed timeouts, and the two headers the policy names.
    /// Nothing here persists between fetches, so "downloads that page, once" is a
    /// property of the configuration and not only of the call site.
    static func makeSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [
            "Accept": accept,
            "User-Agent": userAgent,
        ]
        return configuration
    }

    /// The one request: a plain GET of the exact address, with the policy's
    /// headers set on the request too (the session carries them, but a request
    /// that is inspected in isolation should still read correctly).
    static func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return request
    }
}
