import Foundation

/// What a page gave up: the ingredient lines, and the title and yield if it
/// stated them. Nothing else is kept — the HTML is parsed once and discarded,
/// and the page is never stored (spec §5.1).
struct ExtractedRecipe: Equatable, Sendable {
    var title: String?
    var ingredientLines: [String]
    var servingsText: String?

    init(title: String? = nil, ingredientLines: [String], servingsText: String? = nil) {
        self.title = title
        self.ingredientLines = ingredientLines
        self.servingsText = servingsText
    }
}

/// One HTML start tag, scanned into its name and attributes.
struct HTMLTag: Equatable {
    /// Lowercased element name ("li", "meta").
    let name: String
    /// Attributes, keys lowercased, values with their original case.
    let attributes: [String: String]
    /// `<br />` and friends — no inner text to read.
    let isSelfClosing: Bool

    func attribute(_ name: String) -> String? { attributes[name.lowercased()] }
}

/// Pulls a recipe's ingredient lines out of a downloaded page (spec §5.1), in the
/// order the spec sets: schema.org JSON-LD first, then microdata, then nothing —
/// at which point the Link screen offers *Paste the ingredients instead* and
/// *Open in Safari* rather than guessing at the page's prose.
///
/// Implemented against the **schema.org vocabulary**, not by vendoring a scraper:
/// this walks JSON the site already publishes for search engines. No third-party
/// parser, no ML, no per-site rules — a site that publishes structured data works,
/// and one that doesn't gets an honest "couldn't find a recipe on this page".
/// (`docs/prior-art-and-licensing.md` records the libraries deliberately not used.)
///
/// Both halves are hand-written scanners rather than regular expressions, because
/// real pages vary in every direction the syntax allows: single or double quotes,
/// unquoted values, attributes in any order, extra attributes, CDATA wrappers,
/// several JSON-LD blocks per page, `@graph` wrappers, `@type` as a string or an
/// array, and `recipeIngredient` as a string or an array. Every one of those
/// shapes has a fixture in `RecipeToGroceryListTests/Fixtures/html/`.
///
/// This is **not** a general-purpose HTML parser and must not become one: it reads
/// two specific properties out of markup that is already machine-readable.
enum RecipeHTMLExtractor {

    /// JSON-LD, then microdata. nil when neither yields a single ingredient line —
    /// which is the signal for §5.1's two-button dead end, not an error.
    static func extract(from html: String) -> ExtractedRecipe? {
        if let jsonLD = extractJSONLD(from: html) { return jsonLD }
        return extractMicrodata(from: html)
    }

    // MARK: - JSON-LD

    /// Every `<script type="application/ld+json">` block on the page, walked for
    /// `Recipe` nodes. When a page carries more than one (a recipe plus a
    /// "related recipes" card, say), the node with the most ingredient lines wins:
    /// the main recipe is the one the page is actually about.
    static func extractJSONLD(from html: String) -> ExtractedRecipe? {
        var best: ExtractedRecipe?
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                continue   // one malformed block never costs the page its other blocks
            }
            for node in recipeNodes(in: json) {
                guard let candidate = extracted(from: node) else { continue }
                if candidate.ingredientLines.count > (best?.ingredientLines.count ?? 0) {
                    best = candidate
                }
            }
        }
        return best
    }

    /// The raw text inside every ld+json script block, CDATA unwrapped.
    static func jsonLDBlocks(in html: String) -> [String] {
        var blocks: [String] = []
        var searchRange = html.startIndex..<html.endIndex
        while let open = html.range(of: "<script", options: [.caseInsensitive], range: searchRange) {
            guard let tagEnd = html[open.upperBound...].firstIndex(of: ">") else { break }
            let attributes = String(html[open.upperBound..<tagEnd])
            let afterTag = html.index(after: tagEnd)
            // The close tag bounds the block whether or not we want its contents.
            let closeRange = html.range(of: "</script", options: [.caseInsensitive],
                                        range: afterTag..<html.endIndex)
            let contentEnd = closeRange?.lowerBound ?? html.endIndex
            if attributes.lowercased().contains("application/ld+json") {
                blocks.append(unwrapCDATA(String(html[afterTag..<contentEnd])))
            }
            let next = closeRange?.upperBound ?? html.endIndex
            guard next < html.endIndex else { break }
            searchRange = next..<html.endIndex
        }
        return blocks
    }

    /// `//<![CDATA[ … //]]>` wrappers appear on older CMSes; the JSON is inside.
    ///
    /// The `//` matters: the conventional form comments the CDATA markers out so
    /// the block is also valid JavaScript, which leaves a trailing `//` *inside*
    /// the unwrapped text. Dropping the markers alone therefore yields JSON with a
    /// dangling comment that `JSONSerialization` rejects — so the trailing comment
    /// opener is trimmed too. (Found by running the fixtures through a port of this
    /// file: `jsonld_two_blocks.html` extracted nothing until this was fixed.)
    static func unwrapCDATA(_ text: String) -> String {
        guard let open = text.range(of: "<![CDATA["),
              let close = text.range(of: "]]>", options: .backwards),
              open.upperBound <= close.lowerBound else {
            return text
        }
        var inner = Substring(text[open.upperBound..<close.lowerBound])
        while let last = inner.last, last.isWhitespace { inner = inner.dropLast() }
        if inner.hasSuffix("//") { inner = inner.dropLast(2) }
        return String(inner)
    }

    /// Every `Recipe` node reachable from a decoded JSON value: the value itself,
    /// anything in an array, anything under `@graph`, and — because wrappers vary —
    /// any nested object. Depth-limited so a pathological document can't recurse
    /// without bound.
    static func recipeNodes(in json: Any, depth: Int = 0) -> [[String: Any]] {
        guard depth < 8 else { return [] }
        var found: [[String: Any]] = []
        if let array = json as? [Any] {
            for element in array {
                found.append(contentsOf: recipeNodes(in: element, depth: depth + 1))
            }
            return found
        }
        guard let object = json as? [String: Any] else { return [] }
        if isRecipeType(object["@type"]) {
            found.append(object)
        }
        // Sorted so a page with several nested recipes yields a stable order.
        for key in object.keys.sorted() where key != "@type" {
            guard let value = object[key], value is [String: Any] || value is [Any] else { continue }
            found.append(contentsOf: recipeNodes(in: value, depth: depth + 1))
        }
        return found
    }

    /// `"Recipe"`, `["Recipe", "NewsArticle"]`, `"schema:Recipe"` and
    /// `"http://schema.org/Recipe"` all mean the same thing.
    static func isRecipeType(_ type: Any?) -> Bool {
        if let single = type as? String { return isRecipeTypeName(single) }
        if let many = type as? [Any] {
            return many.contains { ($0 as? String).map(isRecipeTypeName) ?? false }
        }
        return false
    }

    static func isRecipeTypeName(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == "recipe" { return true }
        return lowered.hasSuffix("/recipe") || lowered.hasSuffix(":recipe")
    }

    /// One recipe node → the fields we keep. nil when it has no ingredient lines:
    /// a `Recipe` node without ingredients is a stub (a "related recipe" card),
    /// not something the user can shop from.
    static func extracted(from node: [String: Any]) -> ExtractedRecipe? {
        // `recipeIngredient` is the current property; `ingredients` is the legacy
        // one older WordPress plugins still emit.
        let raw = node["recipeIngredient"] ?? node["ingredients"]
        let lines = stringList(raw)
            .map(HTMLEntities.clean)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return ExtractedRecipe(title: text(node["name"]),
                               ingredientLines: lines,
                               servingsText: text(node["recipeYield"]))
    }

    /// A JSON value that may be a string, a number, or an array of either.
    static func stringList(_ value: Any?) -> [String] {
        switch value {
        case let single as String:
            return [single]
        case let array as [Any]:
            return array.compactMap { element in
                if let string = element as? String { return string }
                if let number = element as? NSNumber { return number.stringValue }
                return nil
            }
        case let number as NSNumber:
            return [number.stringValue]
        default:
            return []
        }
    }

    /// The first usable string of a value, cleaned; nil when there is none.
    static func text(_ value: Any?) -> String? {
        stringList(value).map(HTMLEntities.clean).first { !$0.isEmpty }
    }

    // MARK: - Microdata

    /// The fallback for pages that mark up their ingredients inline (older recipe
    /// plugins): every element carrying `itemprop="recipeIngredient"` (or the
    /// legacy `itemprop="ingredients"`), read for its text.
    static func extractMicrodata(from html: String) -> ExtractedRecipe? {
        var lines: [String] = []
        for property in ["recipeIngredient", "ingredients"] {
            lines = itemPropValues(property, in: html)
            if !lines.isEmpty { break }
        }
        guard !lines.isEmpty else { return nil }
        // The recipe's own `name` beats the document title, which usually carries
        // the site name too ("Focaccia — Invented Kitchen").
        let title = itemPropValues("name", in: html).first ?? documentTitle(html)
        return ExtractedRecipe(title: title,
                               ingredientLines: lines,
                               servingsText: itemPropValues("recipeYield", in: html).first)
    }

    /// The text of every element with `itemprop="<property>"`, tags stripped and
    /// whitespace collapsed. A `content` attribute wins when present (that is what
    /// microdata means on a `<meta>`), otherwise the element's inner text up to its
    /// matching close tag.
    static func itemPropValues(_ property: String, in html: String) -> [String] {
        var values: [String] = []
        let characters = Array(html)
        var index = 0
        while index < characters.count {
            guard let open = nextIndex(of: "<", in: characters, from: index) else { break }
            guard let tagEnd = nextIndex(of: ">", in: characters, from: open + 1) else { break }
            index = tagEnd + 1
            guard let tag = parseTag(characters, from: open + 1, to: tagEnd) else { continue }
            guard let itemprop = tag.attribute("itemprop"),
                  itemprop.split(whereSeparator: { $0.isWhitespace })
                      .contains(where: { $0.caseInsensitiveCompare(property) == .orderedSame }) else {
                continue
            }
            if let content = tag.attribute("content") {
                let cleaned = HTMLEntities.clean(content)
                if !cleaned.isEmpty { values.append(cleaned) }
                continue
            }
            guard !tag.isSelfClosing, !voidTags.contains(tag.name) else { continue }
            let innerEnd = indexOfCloseTag(tag.name, in: characters, from: index) ?? characters.count
            let inner = String(characters[index..<innerEnd])
            let cleaned = HTMLEntities.collapseWhitespace(HTMLEntities.stripTags(inner))
            if !cleaned.isEmpty { values.append(cleaned) }
        }
        return values
    }

    static let voidTags: Set<String> = ["meta", "link", "img", "br", "hr", "input", "source", "area", "col"]

    /// The index of the `<` that opens `</name…>` at or after `from`, or nil.
    /// Nesting is not tracked: ingredient elements in the wild are leaves, and
    /// stopping at the first close of the same name is the honest, cheap rule.
    static func indexOfCloseTag(_ name: String, in characters: [Character], from: Int) -> Int? {
        let needle = Array("</" + name)
        var index = from
        while index + needle.count <= characters.count {
            if matches(needle, in: characters, at: index) { return index }
            index += 1
        }
        return nil
    }

    /// Case-insensitive ASCII compare of a needle against a position.
    static func matches(_ needle: [Character], in characters: [Character], at index: Int) -> Bool {
        guard index + needle.count <= characters.count else { return false }
        for offset in needle.indices {
            let a = characters[index + offset]
            let b = needle[offset]
            if a == b { continue }
            if String(a).lowercased() == String(b).lowercased() { continue }
            return false
        }
        return true
    }

    static func nextIndex(of character: Character, in characters: [Character], from: Int) -> Int? {
        var index = max(from, 0)
        while index < characters.count {
            if characters[index] == character { return index }
            index += 1
        }
        return nil
    }

    /// Scans the body of a start tag (everything between `<` and `>`) into a name
    /// and its attributes. Returns nil for a close tag, a comment or a doctype —
    /// none of which carry an `itemprop`.
    static func parseTag(_ characters: [Character], from start: Int, to end: Int) -> HTMLTag? {
        var index = start
        guard index < end else { return nil }
        if characters[index] == "/" || characters[index] == "!" || characters[index] == "?" { return nil }

        var name = ""
        while index < end, characters[index].isLetter || characters[index].isNumber || characters[index] == "-" {
            name.append(characters[index])
            index += 1
        }
        guard !name.isEmpty else { return nil }

        var attributes: [String: String] = [:]
        var selfClosing = false
        while index < end {
            while index < end, characters[index].isWhitespace { index += 1 }
            guard index < end else { break }
            if characters[index] == "/" {
                selfClosing = true
                index += 1
                continue
            }
            var key = ""
            while index < end, !characters[index].isWhitespace, characters[index] != "=", characters[index] != "/" {
                key.append(characters[index])
                index += 1
            }
            guard !key.isEmpty else { index += 1; continue }
            while index < end, characters[index].isWhitespace { index += 1 }
            guard index < end, characters[index] == "=" else {
                attributes[key.lowercased()] = ""      // valueless attribute ("itemscope")
                continue
            }
            index += 1
            while index < end, characters[index].isWhitespace { index += 1 }
            guard index < end else { break }
            var value = ""
            let quote = characters[index]
            if quote == "\"" || quote == "'" {
                index += 1
                while index < end, characters[index] != quote {
                    value.append(characters[index])
                    index += 1
                }
                index += 1                              // past the closing quote
            } else {
                while index < end, !characters[index].isWhitespace {
                    value.append(characters[index])
                    index += 1
                }
            }
            attributes[key.lowercased()] = value
        }
        return HTMLTag(name: name.lowercased(), attributes: attributes, isSelfClosing: selfClosing)
    }

    /// The page's `<title>`, the fallback recipe name for a microdata page.
    static func documentTitle(_ html: String) -> String? {
        guard let open = html.range(of: "<title", options: [.caseInsensitive]),
              let tagEnd = html[open.upperBound...].firstIndex(of: ">") else {
            return nil
        }
        let afterTag = html.index(after: tagEnd)
        guard let close = html.range(of: "</title", options: [.caseInsensitive],
                                     range: afterTag..<html.endIndex) else {
            return nil
        }
        let title = HTMLEntities.clean(String(html[afterTag..<close.lowerBound]))
        return title.isEmpty ? nil : title
    }
}
