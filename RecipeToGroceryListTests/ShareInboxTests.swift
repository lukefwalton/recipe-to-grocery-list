import XCTest
@testable import RecipeToGroceryList

/// The Share Extension's one-way inbox (spec §5.1). Every test runs against a
/// throwaway directory, never the real App Group container — the same injection
/// the word app uses for `SharedStore(defaults:)`.
final class ShareInboxTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtg-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeInbox() -> ShareInbox { ShareInbox(directory: directory) }

    func testAnUntouchedInboxIsEmpty() throws {
        XCTAssertEqual(try makeInbox().peek(), [], "a missing file is an empty inbox, not an error")
    }

    func testAppendThenPeekRoundTrips() throws {
        let inbox = makeInbox()
        let item = SharedInboxItem(kind: .url, value: "https://example.com/soup")
        try inbox.append(item)
        XCTAssertEqual(try inbox.peek(), [item])
    }

    func testItemsKeepShareOrder() throws {
        let inbox = makeInbox()
        try inbox.append(SharedInboxItem(kind: .url, value: "one"))
        try inbox.append(SharedInboxItem(kind: .text, value: "two"))
        XCTAssertEqual(try inbox.peek().map(\.value), ["one", "two"], "oldest first — the app takes the first")
    }

    func testDrainReturnsEverythingAndClearsTheFile() throws {
        let inbox = makeInbox()
        try inbox.append(SharedInboxItem(kind: .url, value: "one"))
        try inbox.append(SharedInboxItem(kind: .text, value: "two"))

        XCTAssertEqual(try inbox.drain().map(\.value), ["one", "two"])
        XCTAssertEqual(try inbox.peek(), [], "drained means gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.fileURL.path))
    }

    func testDrainingAnEmptyInboxIsHarmless() throws {
        XCTAssertEqual(try makeInbox().drain(), [])
    }

    /// A share the app can't read is a share the user can simply repeat; losing it
    /// is better than throwing into a launch path.
    func testACorruptFileReadsAsEmptyRatherThanThrowing() throws {
        let inbox = makeInbox()
        try Data("this is not json".utf8).write(to: inbox.fileURL)
        XCTAssertEqual(try inbox.peek(), [])
    }

    func testAppendRecoversFromACorruptFile() throws {
        let inbox = makeInbox()
        try Data("{".utf8).write(to: inbox.fileURL)
        try inbox.append(SharedInboxItem(kind: .text, value: "after"))
        XCTAssertEqual(try inbox.peek().map(\.value), ["after"])
    }

    func testAnEmptyFileReadsAsEmpty() throws {
        let inbox = makeInbox()
        try Data().write(to: inbox.fileURL)
        XCTAssertEqual(try inbox.peek(), [])
    }

    /// Someone who shares twenty-one pages before opening the app keeps the twenty
    /// most recent: the newest share is the one they are waiting on.
    func testTheOldestItemsAreDroppedBeyondTheCap() throws {
        let inbox = makeInbox()
        for index in 1...(ShareInbox.maxItems + 3) {
            try inbox.append(SharedInboxItem(kind: .text, value: "item \(index)"))
        }
        let items = try inbox.peek()
        XCTAssertEqual(items.count, ShareInbox.maxItems)
        XCTAssertEqual(items.first?.value, "item 4")
        XCTAssertEqual(items.last?.value, "item \(ShareInbox.maxItems + 3)")
    }

    func testTwoInboxesOnOneDirectoryShareTheFile() throws {
        try makeInbox().append(SharedInboxItem(kind: .url, value: "https://example.com/x"))
        XCTAssertEqual(try makeInbox().peek().count, 1,
                       "the extension writes and the app reads through separate instances")
    }

    func testItemCarriesAParseableTimestamp() throws {
        let inbox = makeInbox()
        try inbox.append(SharedInboxItem(kind: .url, value: "https://example.com/x"))
        let item = try XCTUnwrap(try inbox.peek().first)
        XCTAssertNotNil(RecipeDateFormat.date(item.sharedAt), "sharedAt is written in the store's format")
    }

    func testValueIsStoredVerbatim() throws {
        let inbox = makeInbox()
        let text = "  2 cups flour\n1 egg  "
        try inbox.append(SharedInboxItem(kind: .text, value: text))
        XCTAssertEqual(try inbox.peek().first?.value, text,
                       "the extension never trims or parses — that is the app's job, after the user sees it")
    }

    func testFileNameIsTheDocumentedOne() {
        XCTAssertEqual(makeInbox().fileURL.lastPathComponent, "inbox.json")
    }
}
