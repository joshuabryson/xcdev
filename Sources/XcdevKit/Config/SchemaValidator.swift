import Yams

public struct ConfigIssue: Sendable, Equatable {
    public let path: String
    public let message: String
    public var line: String { path.isEmpty ? message : "\(path): \(message)" }
}

public enum SchemaValidator {
    public static func validate(_ node: Node, against schema: SchemaNode, path: String = "", checkRequired: Bool = true) -> [ConfigIssue] {
        switch schema {
        case .string(_, let allowed):
            return string(node, allowed: allowed, path: path)
        case .integer:
            return node.int == nil ? [ConfigIssue(path: path, message: "expected an integer")] : []
        case .boolean:
            return node.bool == nil ? [ConfigIssue(path: path, message: "expected true or false")] : []
        case .stringList:
            return stringList(node, path: path)
        case .stringMap:
            return stringMap(node, path: path)
        case .object(_, let fields):
            return object(node, fields: fields, path: path, checkRequired: checkRequired)
        case .map(_, let valueSchema):
            guard let mapping = node.mapping else { return [ConfigIssue(path: path, message: "expected a mapping")] }
            return mapping.flatMap { key, value in
                validate(value, against: valueSchema, path: join(path, key.string ?? "?"), checkRequired: checkRequired)
            }
        case .reserved(let purpose):
            return [ConfigIssue(path: path, message: "is reserved for \(purpose), which this version of xcd does not support yet")]
        }
    }

    private static func string(_ node: Node, allowed: [String]?, path: String) -> [ConfigIssue] {
        guard let value = node.scalar?.string else { return [ConfigIssue(path: path, message: "expected a string")] }
        if let allowed, !allowed.contains(value) {
            return [ConfigIssue(path: path, message: "must be one of: \(allowed.joined(separator: ", "))")]
        }
        return []
    }

    private static func stringList(_ node: Node, path: String) -> [ConfigIssue] {
        guard let items = node.sequence else { return [ConfigIssue(path: path, message: "expected a list of strings")] }
        return items.enumerated().compactMap { index, item in
            item.scalar == nil ? ConfigIssue(path: "\(path)[\(index)]", message: "expected a string") : nil
        }
    }

    private static func stringMap(_ node: Node, path: String) -> [ConfigIssue] {
        guard let mapping = node.mapping else {
            return [ConfigIssue(path: path, message: "expected a mapping of string to string")]
        }
        return mapping.compactMap { key, value in
            value.scalar == nil ? ConfigIssue(path: join(path, key.string ?? "?"), message: "expected a string") : nil
        }
    }

    private static func object(_ node: Node, fields: [SchemaField], path: String, checkRequired: Bool) -> [ConfigIssue] {
        guard let mapping = node.mapping else { return [ConfigIssue(path: path, message: "expected a mapping")] }
        var issues: [ConfigIssue] = []
        for (keyNode, value) in mapping {
            let key = keyNode.string ?? ""
            if let field = fields.first(where: { $0.name == key }) {
                issues += validate(value, against: field.node, path: join(path, key), checkRequired: checkRequired)
            } else {
                issues.append(unknownKey(key, in: fields, path: path))
            }
        }
        guard checkRequired else { return issues }
        let present = Set(mapping.keys.compactMap(\.string))
        for field in fields where field.required && !present.contains(field.name) {
            issues.append(ConfigIssue(path: join(path, field.name), message: "is required"))
        }
        return issues
    }

    private static func unknownKey(_ key: String, in fields: [SchemaField], path: String) -> ConfigIssue {
        if path.isEmpty, ConfigSchema.reservedTopLevelKeys.contains(key) {
            return ConfigIssue(path: key, message: "is reserved for a future version of xcd and not supported yet")
        }
        let known = fields.filter { !$0.node.isReserved }.map(\.name)
        let hint = Suggest.closest(to: key, in: known, limit: 1).first.map { " (did you mean '\($0)'?)" } ?? ""
        return ConfigIssue(path: join(path, key), message: "unknown key" + hint)
    }

    private static func join(_ base: String, _ key: String) -> String {
        base.isEmpty ? key : "\(base).\(key)"
    }
}
