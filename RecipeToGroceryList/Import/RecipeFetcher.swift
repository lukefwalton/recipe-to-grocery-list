import Foundation

/// The app's only network call, and nothing more (spec §5.1). One `GET` of the
/// exact address the user handed over, on an ephemeral, cookie-less session, with
/// the redirect, size and status rules of `RecipeFetchPolicy` enforced as the
/// bytes arrive. No retries: a failure is reported and the user decides whether
/// to tap again.
///
/// The rules live in `RecipeFetchPolicy` (pure, unit-tested); this type is the
/// thin plumbing that obeys them. **Not unit-tested** — it needs a server — so it
/// is kept deliberately small and every decision it makes is a call into the
/// policy. `PageFetching` is the seam the Link screen and its tests inject.
///
/// One `FetchSession` per fetch: it owns the delegate callbacks, the accumulated
/// bytes and the single continuation, so two concurrent fetches can never share
/// state. The session is invalidated at the end, which releases the delegate.
final class RecipeFetcher: NSObject, PageFetching {
    override init() {
        super.init()
    }

    func fetch(_ url: URL) async throws -> FetchedPage {
        let fetch = FetchSession(url: url)
        return try await fetch.run()
    }
}

/// One in-flight page download. `@unchecked Sendable` because every mutable field
/// is touched only from the URLSession delegate queue (a serial queue this type
/// owns) or, for the continuation, exactly once under that queue's serialization.
private final class FetchSession: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let url: URL
    private var data = Data()
    private var finalURL: URL
    private var redirectCount = 0
    /// A policy violation seen mid-flight. It wins over whatever error the
    /// cancellation itself produces, so the user reads "Only https links are
    /// supported" rather than "cancelled".
    private var policyError: RecipeFetchError?
    private var continuation: CheckedContinuation<FetchedPage, Error>?
    private var isFinished = false
    /// Delegate callbacks are delivered on this queue's single thread, so the
    /// fields above need no further locking.
    private let delegateQueue: OperationQueue

    init(url: URL) {
        self.url = url
        self.finalURL = url
        self.delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "RecipeFetcher"
        super.init()
    }

    func run() async throws -> FetchedPage {
        let session = URLSession(configuration: RecipeFetchPolicy.makeSessionConfiguration(),
                                 delegate: self,
                                 delegateQueue: delegateQueue)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.dataTask(with: RecipeFetchPolicy.makeRequest(url)).resume()
        }
    }

    /// Resume exactly once, whatever order the callbacks arrive in.
    private func finish(_ result: Result<FetchedPage, Error>) {
        guard !isFinished else { return }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectCount += 1
        if let error = RecipeFetchPolicy.redirectError(to: request.url, redirectCount: redirectCount) {
            policyError = error
            completionHandler(nil)      // stop here; didComplete reports the policy error
            task.cancel()
            return
        }
        if let target = request.url { finalURL = target }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let policyError {
            finish(.failure(policyError))
            return
        }
        if let error {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                finish(.failure(RecipeFetchError.timedOut))
            } else {
                finish(.failure(RecipeFetchError.network(error.localizedDescription)))
            }
            return
        }
        finish(.success(FetchedPage(finalURL: finalURL, html: Self.decode(data))))
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        // A refused redirect passes nil to its completion handler, which delivers
        // the 3xx here as the "final" response before the cancel lands. The first
        // error is the real one; never let it be overwritten by badStatus(301).
        if policyError != nil {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) else {
                policyError = .badStatus(http.statusCode)
                completionHandler(.cancel)
                return
            }
            if let target = http.url { finalURL = target }
        }
        // A declared length over the cap is refused before a single byte lands.
        if response.expectedContentLength != NSURLSessionTransferSizeUnknown,
           response.expectedContentLength > Int64(RecipeFetchPolicy.maxBytes) {
            policyError = .responseTooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Undeclared length, or a lying one: stop the moment the cap is crossed.
        guard self.data.count + data.count <= RecipeFetchPolicy.maxBytes else {
            policyError = .responseTooLarge
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    /// UTF-8, falling back to Latin-1 for the older recipe sites that still serve
    /// `windows-1252`-ish bytes. Never throws: a page that decodes to nothing
    /// simply yields no ingredients and the user sees the "couldn't find a recipe"
    /// screen (§5.1) rather than an error about encodings.
    static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
