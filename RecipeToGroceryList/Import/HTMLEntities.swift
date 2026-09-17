import Foundation

/// The small amount of HTML handling the URL path needs (spec §5.1): decode the
/// entities that appear in ingredient text, strip tags out of a microdata
/// element's inner text, and collapse whitespace.
///
/// Hand-rolled rather than vendored, per the family's "port, don't depend" rule
/// (`a-new-word-every-day/docs/learnings/002-fsrs-review.md`). This is not a
/// general-purpose HTML library and must not become one: the app reads
/// `recipeIngredient` strings, not documents. `NSAttributedString`'s HTML
/// importer would do more, but it runs WebKit on the main thread — far too much
/// machinery, and a policy problem, for turning `&frac12;` into `½`.
enum HTMLEntities {
    /// The named entities that actually show up in recipe ingredient lines.
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "deg": "°", "times": "×",
        "frac12": "½", "frac13": "⅓", "frac23": "⅔", "frac14": "¼", "frac34": "¾",
        "frac18": "⅛", "frac38": "⅜", "frac58": "⅝", "frac78": "⅞",
        "ndash": "–", "mdash": "—", "hellip": "…",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "agrave": "à", "ccedil": "ç",
        "ntilde": "ñ", "uuml": "ü", "ouml": "ö", "auml": "ä",
    ]

    /// Decodes named (`&amp;`) and numeric (`&#189;`, `&#x00BD;`) references.
    /// An unknown or malformed reference is left exactly as written — showing
    /// `&foo;` is honest; guessing is not.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result.append(contentsOf: rest[..<ampersand])
            let afterAmpersand = rest.index(after: ampersand)
            // An entity is short; a stray "&" in prose must not scan to the end.
            let window = rest[afterAmpersand...].prefix(12)
            guard let semicolon = window.firstIndex(of: ";") else {
                result.append("&")
                rest = rest[afterAmpersand...]
                continue
            }
            let body = rest[afterAmpersand..<semicolon]
            if let decoded = decodeReference(body) {
                result.append(decoded)
            } else {
                result.append("&")
                result.append(contentsOf: body)
                result.append(";")
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        result.append(contentsOf: rest)
        return result
    }

    /// The text between `&` and `;`, decoded, or nil when it is not a reference
    /// this decoder knows.
    private static func decodeReference(_ body: Substring) -> String? {
        guard !body.isEmpty else { return nil }
        if body.first == "#" {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return named[String(body).lowercased()]
    }

    /// Plain text out of an HTML fragment: `<script>` and `<style>` blocks go
    /// entirely (tags *and* contents), block-level closers become newlines so two
    /// list items never run into one word, every other tag is dropped, and what's
    /// left is entity-decoded.
    static func stripTags(_ html: String) -> String {
        var result = ""
        result.reserveCapacity(html.count)
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            result.append(contentsOf: rest[..<open])
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: ">") else {
                // An unclosed "<" is text, not a tag.
                result.append(contentsOf: rest[open...])
                rest = rest[rest.endIndex...]
                break
            }
            let tag = rest[afterOpen..<close]
            let name = tagName(tag)
            if name == "script" || name == "style", !tag.hasPrefix("/") {
                // Skip to the matching close tag; an unterminated block eats the rest.
                if let end = rest[close...].range(of: "</\(name)", options: [.caseInsensitive]),
                   let endClose = rest[end.upperBound...].firstIndex(of: ">") {
                    rest = rest[rest.index(after: endClose)...]
                } else {
                    rest = rest[rest.endIndex...]
                }
                continue
            }
            if breakingTags.contains(name) {
                result.append("\n")
            }
            rest = rest[rest.index(after: close)...]
        }
        result.append(contentsOf: rest)
        return decode(result)
    }

    /// Tags whose boundary is a line break in the text — otherwise `<li>a</li><li>b</li>`
    /// reads as "ab".
    static let breakingTags: Set<String> = [
        "br", "p", "li", "div", "tr", "ul", "ol", "table", "h1", "h2", "h3", "h4", "h5", "h6",
    ]

    /// The lowercased element name of a tag body, without `/` or attributes.
    static func tagName(_ tag: Substring) -> String {
        var name = tag
        if name.hasPrefix("/") { name = name.dropFirst() }
        let letters = name.prefix { $0.isLetter || $0.isNumber }
        return String(letters).lowercased()
    }

    /// Every run of whitespace (including the non-breaking space `&nbsp;` decodes
    /// to) becomes one plain space, and the result is trimmed.
    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    /// The usual pipeline for one extracted string: decode, then collapse.
    static func clean(_ text: String) -> String {
        collapseWhitespace(decode(text))
    }
}
