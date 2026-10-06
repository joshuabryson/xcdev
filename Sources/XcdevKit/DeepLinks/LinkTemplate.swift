import Foundation

/// Text with `{name}` placeholders. `{{` and `}}` are literal braces.
struct LinkTemplate: Sendable, Equatable {
    enum Part: Sendable, Equatable {
        case text(String)
        case placeholder(String)
    }

    /// Why a template could not be read, in words that follow the key's path in a config error.
    struct Problem: Error, Sendable, Equatable {
        let message: String
    }

    let parts: [Part]

    /// Throws `Problem` for a `{` that is never closed, a `}` that closes nothing, and an empty `{}`.
    init(_ text: String) throws {
        var parts: [Part] = []
        var literal = ""
        var rest = Substring(text)
        while let character = rest.first {
            rest = rest.dropFirst()
            if character != "{" && character != "}" {
                literal.append(character)
            } else if rest.first == character {                 // `{{` and `}}`
                literal.append(character)
                rest = rest.dropFirst()
            } else {
                let name = try Self.name(after: character, in: &rest)
                if !literal.isEmpty { parts.append(.text(literal)) }
                literal = ""
                parts.append(.placeholder(name))
            }
        }
        if !literal.isEmpty { parts.append(.text(literal)) }
        self.parts = parts
    }

    /// The name of the placeholder that `brace` opens, moving `rest` past its `}`.
    private static func name(after brace: Character, in rest: inout Substring) throws -> String {
        guard brace == "{" else { throw Problem(message: "has a '}' that closes nothing (write '}}' for a literal brace)") }
        guard let close = rest.firstIndex(of: "}"), !rest[..<close].contains("{") else {
            throw Problem(message: "has a '{' that is never closed (write '{{' for a literal brace)")
        }
        guard close != rest.startIndex else { throw Problem(message: "has an empty placeholder '{}'") }
        let name = String(rest[..<close])
        rest = rest[rest.index(after: close)...]
        return name
    }

    /// The placeholder names, in order. A name used twice appears twice.
    var names: [String] {
        parts.compactMap { part in
            if case .placeholder(let name) = part { return name }
            return nil
        }
    }

    /// The text with each placeholder replaced by `value(name)`. One pass: a value that holds `{…}` is not read again.
    func filled(_ value: (String) -> String) -> String {
        parts.map { part in
            switch part {
            case .text(let text): return text
            case .placeholder(let name): return value(name)
            }
        }.joined()
    }

    /// When the template is a query item whose whole value is one placeholder (`tab={tab}`), that placeholder's name.
    var wholeValueName: String? {
        guard parts.count >= 2, case .placeholder(let name) = parts[parts.count - 1] else { return nil }
        let key = parts.dropLast().map { part -> String in
            if case .text(let text) = part { return text }
            return ""
        }.joined()
        guard case .text(let before) = parts[parts.count - 2], before.hasSuffix("="),
              key.filter({ $0 == "=" }).count == 1 else { return nil }
        return name
    }
}

/// A `url` template, split where the link's query items are before anything is filled in, so a value that holds
/// `?`, `&`, or `#` cannot change which items exist.
struct URLTemplate: Sendable, Equatable {
    /// Everything before the first `?` (or before the `#`, when there is no `?`).
    let head: LinkTemplate
    /// The `&`-separated parts between the first `?` and the `#` or the end. Nil when the link has no `?`.
    let items: [LinkTemplate]?
    /// What follows the first `#`. Nil when the link has none.
    let fragment: LinkTemplate?

    init(_ text: String) throws {
        var before = Substring(text)
        var fragment: LinkTemplate?
        if let hash = before.firstIndex(of: "#") {
            fragment = try LinkTemplate(String(before[before.index(after: hash)...]))
            before = before[..<hash]
        }
        var items: [LinkTemplate]?
        if let mark = before.firstIndex(of: "?") {
            items = try before[before.index(after: mark)...].split(separator: "&", omittingEmptySubsequences: false)
                .map { try LinkTemplate(String($0)) }
            before = before[..<mark]
        }
        head = try LinkTemplate(String(before))
        self.items = items
        self.fragment = fragment
    }

    /// Every placeholder name in the link, in order.
    var names: [String] { head.names + (items ?? []).flatMap(\.names) + (fragment?.names ?? []) }

    /// The names in `optional` that the link uses anywhere other than as the whole value of a query item.
    func misplaced(optional: Set<String>) -> [String] {
        var found = (head.names + (fragment?.names ?? [])).filter(optional.contains)
        for item in items ?? [] {
            let whole = item.wholeValueName
            let names = item.names.filter(optional.contains)
            found += whole.map { name in names.count == 1 && names[0] == name ? [] : names } ?? names
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// The link. `value` gives each placeholder's text, already encoded, or nil for an optional parameter that was
    /// left out: its query item is dropped, and the `?` with it when no items remain.
    func filled(_ value: (String) -> String?) -> String {
        var link = head.filled { value($0) ?? "" }
        let kept = (items ?? []).filter { item in item.wholeValueName.map { value($0) != nil } ?? true }
        if !kept.isEmpty { link += "?" + kept.map { item in item.filled { value($0) ?? "" } }.joined(separator: "&") }
        if let fragment { link += "#" + fragment.filled { value($0) ?? "" } }
        return link
    }
}

enum LinkEncoding {
    /// The characters a URL never gives a meaning to: letters, digits, `-`, `.`, `_`, and `~`.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `value` with every other character percent-encoded, so it cannot change a link's structure.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}

public enum LinkScheme {
    /// The scheme `url` starts with, as written (a letter, then letters, digits, `+`, `-`, and `.`, then `:`), or nil.
    public static func of(_ url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        return String(scheme)
    }

    /// http and https links go through the system like a tapped link; every other scheme is the app's own.
    public static func isWeb(_ scheme: String) -> Bool {
        ["http", "https"].contains(scheme.lowercased())
    }
}
