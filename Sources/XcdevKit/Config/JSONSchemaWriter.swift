import Foundation

public enum JSONSchemaWriter {
    public static func write(_ node: SchemaNode = ConfigSchema.v1) -> String {
        var root = object(node)
        root["$schema"] = "https://json-schema.org/draft/2020-12/schema"
        root["title"] = ".xcdev.yml"
        let data = (try? JSONSerialization.data(withJSONObject: root,
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public static func object(_ node: SchemaNode) -> [String: Any] {
        switch node {
        case .string(let description, let allowed):
            var result: [String: Any] = ["type": "string", "description": description]
            if let allowed { result["enum"] = allowed }
            return result
        case .integer(let description):
            return ["type": "integer", "description": description]
        case .stringList(let description):
            return ["type": "array", "items": ["type": "string"], "description": description]
        case .stringMap(let description):
            return ["type": "object", "additionalProperties": ["type": "string"], "description": description]
        case .object(let description, let fields):
            var result: [String: Any] = [
                "type": "object",
                "description": description,
                "additionalProperties": false,
                "properties": Dictionary(uniqueKeysWithValues: fields.map { ($0.name, object($0.node)) }),
            ]
            let required = fields.filter(\.required).map(\.name)
            if !required.isEmpty { result["required"] = required }
            return result
        case .map(let description, let value):
            return ["type": "object", "description": description, "additionalProperties": object(value)]
        }
    }
}
