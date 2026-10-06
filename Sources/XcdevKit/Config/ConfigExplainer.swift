import Foundation

/// One documented config key, as `xcd config explain` shows it. User-named keys appear as `<name>`.
public struct ConfigKeyDoc: Codable, Sendable, Equatable {
    /// e.g. "devices.<name>.runtime".
    public let key: String
    /// "string", "integer", "list of strings", "map of strings", "section", or "named entries".
    public let type: String
    public let summary: String
    public let required: Bool
    public let allowed: [String]?
    public let defaultValue: String?
    public let example: String
}

/// Documentation for every config key, read from `ConfigSchema` (the same source validation uses).
public enum ConfigExplainer {
    public static func keys(_ schema: SchemaNode = ConfigSchema.v1) -> [ConfigKeyDoc] {
        var docs: [ConfigKeyDoc] = []
        func walk(_ node: SchemaNode, prefix: String, parentExample: String) {
            switch node {
            case .object(_, let fields):
                for field in fields where !field.node.isReserved {
                    let key = prefix.isEmpty ? field.name : prefix + "." + field.name
                    docs.append(ConfigKeyDoc(key: key, type: typeName(field.node), summary: field.node.summary,
                                             required: field.required, allowed: allowed(field.node),
                                             defaultValue: field.defaultValue, example: field.example))
                    walk(field.node, prefix: key, parentExample: field.example)
                }
            case .map(_, let value):
                let key = prefix + ".<name>"
                docs.append(ConfigKeyDoc(key: key, type: typeName(value), summary: value.summary, required: false,
                                         allowed: allowed(value), defaultValue: nil, example: parentExample))
                walk(value, prefix: key, parentExample: parentExample)
            case .string, .integer, .boolean, .stringList, .stringMap, .reserved:
                break
            }
        }
        walk(schema, prefix: "", parentExample: "")
        return docs
    }

    /// The doc for `key`. A user-named segment may be written as any name ("devices.iphone.type") or as `<name>`.
    public static func explain(_ key: String) throws -> ConfigKeyDoc {
        let all = keys()
        let wanted = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let doc = all.first(where: { matches($0.key, wanted) }) { return doc }
        let suggestions = Suggest.closest(to: key, in: all.map(\.key))
        throw XcdError(.usage, "'\(key)' is not a .xcdev.yml key",
                       next: suggestions.isEmpty
                           ? "run `xcd config explain` to list every key"
                           : "did you mean \(suggestions.map { "`\($0)`" }.joined(separator: ", "))? `xcd config explain` lists every key")
    }

    /// Direct children of `key` (for sections), e.g. devices.<name> → devices.<name>.type, ….
    public static func children(of doc: ConfigKeyDoc) -> [ConfigKeyDoc] {
        let depth = doc.key.split(separator: ".").count + 1
        return keys().filter { $0.key.hasPrefix(doc.key + ".") && $0.key.split(separator: ".").count == depth }
    }

    static func matches(_ docKey: String, _ wanted: [String]) -> Bool {
        let parts = docKey.split(separator: ".").map(String.init)
        guard parts.count == wanted.count else { return false }
        return zip(parts, wanted).allSatisfy { part, given in
            part == given || (part == "<name>" && !given.isEmpty)
        }
    }

    static func typeName(_ node: SchemaNode) -> String {
        switch node {
        case .string: return "string"
        case .integer: return "integer"
        case .boolean: return "true or false"
        case .stringList: return "list of strings"
        case .stringMap: return "map of strings"
        case .object: return "section"
        case .map: return "named entries"
        case .reserved: return "reserved"
        }
    }

    static func allowed(_ node: SchemaNode) -> [String]? {
        if case .string(_, let allowed) = node { return allowed }
        return nil
    }
}

/// `xcd config explain [<key>]`.
public struct ConfigExplainReport: Reportable {
    /// One key's doc, or nil when listing every key.
    public let doc: ConfigKeyDoc?
    /// With a key: its child keys (for sections). Without: every key.
    public let keys: [ConfigKeyDoc]

    public init(key: String?) throws {
        if let key {
            let doc = try ConfigExplainer.explain(key)
            self.doc = doc
            keys = ConfigExplainer.children(of: doc)
        } else {
            doc = nil
            keys = ConfigExplainer.keys()
        }
    }

    public var text: String {
        guard let doc else {
            let width = (keys.map(\.key.count).max() ?? 0) + 2
            let rows = keys.map { $0.key.padding(toLength: width, withPad: " ", startingAt: 0) + $0.summary }
            return (rows + ["details: xcd config explain <key>"]).joined(separator: "\n")
        }
        var lines = ["\(doc.key) (\(doc.type)\(doc.required ? ", required" : ""))", doc.summary]
        if let allowed = doc.allowed { lines.append("allowed: " + allowed.joined(separator: ", ")) }
        if let value = doc.defaultValue { lines.append("default: " + value) }
        lines.append("example:")
        lines += doc.example.split(separator: "\n").map { "  " + $0 }
        if !keys.isEmpty { lines.append("keys: " + keys.map(\.key).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }
}
