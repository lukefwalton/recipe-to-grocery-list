import Foundation

/// One thing the user shared into the app: a link or some plain text, with the
/// moment they shared it. `Codable` because the inbox is a JSON file in the App
/// Group container — the only thing the extension and the app exchange (§5.1).
struct SharedInboxItem: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case url, text
    }

    let kind: Kind
    /// The shared URL string or the shared text, verbatim. The extension never
    /// parses, trims or validates it — that is the app's job, after the user sees it.
    let value: String
    /// ISO-8601, written with the same formatter as every stored timestamp.
    let sharedAt: String

    init(kind: Kind, value: String, sharedAt: String = RecipeDateFormat.string(Date())) {
        self.kind = kind
        self.value = value
        self.sharedAt = sharedAt
    }
}

/// The Share Extension's **one-way inbox** (spec §5.1): the extension appends,
/// the app drains. A small JSON array in a file in the App Group container —
/// deliberately not a database, not shared `UserDefaults`, and not a two-way
/// channel. The extension does zero parsing and zero networking; it writes here
/// and says "Added. Open Recipe to Grocery List to finish."
///
/// Failure is never fatal on either side. A missing file is an empty inbox; a
/// corrupt one is an empty inbox (a share that can't be read is a share the user
/// can simply repeat, and losing it is better than blocking a launch). The
/// directory is injected so tests use a temp directory and never touch the real
/// container — the same shape as `SharedStore(defaults:)` in
/// `WordOfTheDay/Shared/SharedStore.swift` at `a-new-word-every-day@e829bcc9c0dc`.
///
/// Foundation only: this file compiles into the extension target, which links no
/// design system, no SQLite and none of `Storage/`.
final class ShareInbox {
    static let fileName = "inbox.json"

    /// A hard cap so a user who shares twenty pages before opening the app can't
    /// grow an unbounded file. The oldest entries are dropped first: the most
    /// recent share is the one they are waiting on.
    static let maxItems = 20

    let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// The production inbox, or nil when the App Group container is unavailable
    /// (missing entitlement / provisioning). nil simply means "no inbox": the app
    /// skips draining and the extension reports that it couldn't save.
    static func appGroup() -> ShareInbox? {
        guard let container = AppGroup.containerURL() else { return nil }
        return ShareInbox(directory: container)
    }

    /// Append one shared item. Read-modify-write, then one atomic write, so a
    /// reader (or a second share) never sees a half-written file. Over
    /// `maxItems`, the oldest entries are dropped.
    func append(_ item: SharedInboxItem) throws {
        var items = (try? peek()) ?? []
        items.append(item)
        if items.count > Self.maxItems {
            items.removeFirst(items.count - Self.maxItems)
        }
        let data = try JSONEncoder().encode(items)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Everything waiting, oldest first. `[]` when the file is missing, empty or
    /// undecodable — the inbox is a convenience, and an unreadable one must never
    /// throw into a launch path.
    func peek() throws -> [SharedInboxItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([SharedInboxItem].self, from: data)) ?? []
    }

    /// Take everything and clear the inbox. The app calls this on foreground; it
    /// re-appends anything it doesn't act on immediately, so nothing the user
    /// shared is silently dropped (§1).
    @discardableResult
    func drain() throws -> [SharedInboxItem] {
        let items = try peek()
        removeFile()
        return items
    }

    /// Deletes the backing file, ignoring "it wasn't there".
    private func removeFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
