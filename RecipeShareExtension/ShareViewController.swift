import UIKit
import UniformTypeIdentifiers

/// The Share Extension (spec §5.1). It does **zero parsing and zero networking**:
/// it takes the URL or text the user shared, appends it to the App Group inbox,
/// and says "Added. Open Recipe to Grocery List to finish." The app drains the
/// inbox on its next foreground and opens the Confirm flow.
///
/// Why so little: extensions run under a hard memory limit, have no Foundation
/// Models access, and this app's database deliberately lives in the main app's
/// private sandbox (`docs/learnings/001-scaffold-and-inheritance.md`). So the
/// extension never opens the database, names none of the storage layer, and links
/// no design system — `scripts/check_store_boundary.sh` fails CI if that ever
/// stops being true. It compiles only its own folder plus
/// `RecipeToGroceryList/Shared`.
///
/// Consequently the UI here is plain UIKit on system colors, not the family
/// palette: pulling `LFWDesignSystem` into a share sheet for two labels would
/// trade the extension's whole reason for existing against a gradient.
///
/// NOT COMPILED HERE (no UIKit on Linux). Correct by inspection; the share sheet
/// itself is a device step.
final class ShareViewController: UIViewController {

    private let messageLabel = UILabel()
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        handleSharedItem()
    }

    // MARK: - Intake

    /// Takes the first attachment that is a URL or plain text and files it. A share
    /// sheet can hand over several representations of one thing; the first usable
    /// one wins, and the rest are ignored rather than filed twice.
    private func handleSharedItem() {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []

        let urlType = UTType.url.identifier
        let textType = UTType.plainText.identifier

        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(urlType) }) {
            load(provider, typeIdentifier: urlType, kind: .url)
            return
        }
        if let provider = attachments.first(where: { $0.hasItemConformingToTypeIdentifier(textType) }) {
            load(provider, typeIdentifier: textType, kind: .text)
            return
        }
        show("Nothing to add.")
    }

    /// `loadItem` may hand back a `URL`, `NSURL`, `String`, `NSString` or `Data`
    /// depending on the source app, so every shape is unwrapped here.
    private func load(_ provider: NSItemProvider, typeIdentifier: String, kind: SharedInboxItem.Kind) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            let value = Self.string(from: item)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.show("Nothing to add.")
                    return
                }
                self.save(SharedInboxItem(kind: kind, value: value))
            }
        }
    }

    private static func string(from item: NSSecureCoding?) -> String? {
        switch item {
        case let url as URL: return url.absoluteString
        case let text as String: return text
        case let data as Data: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    /// Appends to the inbox. A missing App Group container or a write failure is
    /// reported honestly — the user can still paste the link into the app — rather
    /// than showing "Added" for something that was not.
    private func save(_ item: SharedInboxItem) {
        guard let inbox = ShareInbox.appGroup() else {
            show("Couldn't save that. Open the app and paste the link instead.")
            return
        }
        do {
            try inbox.append(item)
            show("Added. Open Recipe to Grocery List to finish.")
        } catch {
            show("Couldn't save that. Open the app and paste the link instead.")
        }
    }

    // MARK: - UI

    private func configureUI() {
        view.backgroundColor = .systemBackground

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .label
        messageLabel.text = "Adding…"

        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        doneButton.titleLabel?.adjustsFontForContentSizeCategory = true
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)

        view.addSubview(messageLabel)
        view.addSubview(doneButton)

        NSLayoutConstraint.activate([
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),

            doneButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 24),
            doneButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func show(_ message: String) {
        messageLabel.text = message
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
