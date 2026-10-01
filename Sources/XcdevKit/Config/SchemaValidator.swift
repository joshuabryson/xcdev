import Yams

public struct ConfigIssue: Sendable, Equatable {
    public let path: String
    public let message: String
    public var line: String { path.isEmpty ? message : "\(path): \(message)" }
}

public enum SchemaValidator {
    public static func validate(_ node: Node, against schema: SchemaNode, path: String = "") -> [ConfigIssue] {
        switch schema {
        case .string(_, let allowed):
            guard let value = node.scalar?.string else { return [ConfigIssue(path: path, message: "expected a string")] }
            if let allowed, !allowed.contains(value) {
                return [ConfigIssue(path: path, message: "must be one of: \(allowed.joined(separator: ", "))")]
            }
            return []

        case .integer:
            return node.int == nil ? [ConfigIssue(path: path, message: "expected an integer")] : []

        case .stringList:
            guard let items = node.sequence else { return [ConfigIssue(path: path, message: "expected a list of strings")] }
            return items.enumerated().compactMap { index, item in
                item.scalar == nil ? ConfigIssue(path: "\(path)[\(index)]", message: "expected a string") : nil
            }

        case .stringMap:
            guard let mapping = node.mapping else {
                return [ConfigIssue(path: path, message: "expected a mapping of string to string")]
            }
            return mapping.compactMap { key, value in
                value.scalar == nil ? ConfigIssue(path: join(path, key.string ?? "?"), message: "expected a string") : nil
            }

        case .object(_, let fields):
            guard let mapping = node.mapping else { return [ConfigIssue(path: path, message: "expected a mapping")] }
            var issues: [ConfigIssue] = []
            let known = fields.map(\.name)
            for (keyNode, value) in mapping {
                let key = keyNode.string ?? ""
                let keyPath = join(path, key)
                if let field = fields.first(where: { $0.name == key }) {
                    issues += validate(value, against: field.node, path: keyPath)
                } else if path.isEmpty, ConfigSchema.reservedTopLevelKeys.contains(key) {
                    issues.append(ConfigIssue(path: keyPath, message: "is reserved for a future version of xcd and not supported yet"))
                } else {
                    let hint = Suggest.closest(to: key, in: known, limit: 1).first.map { " (did you mean '\($0)'?)" } ?? ""
                    issues.append(ConfigIssue(path: keyPath, message: "unknown key" + hint))
                }
            }
            let present = Set(mapping.keys.compactMap(\.string))
            for field in fields where field.required && !present.contains(field.name) {
                issues.append(ConfigIssue(path: join(path, field.name), message: "is required"))
            }
            return issues

        case .map(_, let valueSchema):
            guard let mapping = node.mapping else { return [ConfigIssue(path: path, message: "expected a mapping")] }
            return mapping.flatMap { key, value in
                validate(value, against: valueSchema, path: join(path, key.string ?? "?"))
            }
        }
    }

    private static func join(_ base: String, _ key: String) -> String {
        base.isEmpty ? key : "\(base).\(key)"
    }
}
