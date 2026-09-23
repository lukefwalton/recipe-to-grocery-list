import Foundation

/// The App Group the app and the Share Extension share. It exists for **exactly
/// one thing** (spec §5.1): the extension's one-way inbox — a small JSON file
/// holding the link or text the user shared, which the app drains on foreground.
///
/// The database is deliberately **not** here. It lives in the app's private
/// sandbox (`AppDatabase.databaseURL()`), because nothing else ever opens it:
/// the extension does no parsing, no networking and no SQLite (extension memory
/// limits, and no Foundation Models access in extensions, are the deeper reason).
/// `scripts/check_store_boundary.sh` turns that claim into a CI failure rather
/// than a comment, and the privacy policy can describe the container in one
/// sentence.
///
/// The identifier is duplicated in `project.yml` (each target's
/// `com.apple.security.application-groups` entitlement) because nothing can read
/// a build setting from Swift at compile time — the strings stay in sync by hand,
/// and `scripts/check_appgroup_sync.sh` (run in CI) fails the build if they drift.
/// Shape from `WordOfTheDay/Shared/AppGroup.swift` at
/// `a-new-word-every-day@e829bcc9c0dc`.
enum AppGroup {
    static let identifier = "group.com.lukewalton.recipetogrocerylist"

    /// The shared container, or nil when the App Group isn't provisioned for this
    /// target (a signing/provisioning problem). Callers degrade rather than crash:
    /// `ShareInbox.appGroup()` returns nil, the app simply has no inbox to drain,
    /// and every other feature keeps working.
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
