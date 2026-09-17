import Foundation

/// The single canonical ISO8601 parser/formatter for the store's timestamps.
/// Lives in **Shared** — the module compiled into both the app and the Share
/// Extension — so the inbox's `sharedAt` and the database's `created_at` are
/// written in exactly one format, and the formatter is allocated once per
/// process instead of once per call site.
///
/// Ported verbatim from `WorkoutChatLog/Shared/WorkoutDateFormat.swift` at
/// `workout-logger@5bffddfb80fc`. `ISO8601DateFormatter` is documented
/// thread-safe for `string(from:)` / `date(from:)` once configured, so a single
/// `static let` is the right shape (that caveat applies to `DateFormatter`, not
/// this type).
enum RecipeDateFormat {
    static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(_ date: Date) -> String { iso.string(from: date) }

    /// nil for nil or unparseable input — a stored timestamp the app can't read
    /// is surfaced as "unknown", never as a fabricated date.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return iso.date(from: text)
    }
}
