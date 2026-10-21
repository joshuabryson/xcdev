import Foundation
import Testing
@testable import XcdevKit

@Suite struct JSONSchemaWriterTests {
    @Test func emitsStrictDraft2020Schema() throws {
        let json = JSONSchemaWriter.write()
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(root["$schema"] as? String == "https://json-schema.org/draft/2020-12/schema")
        #expect(root["additionalProperties"] as? Bool == false)
        #expect(Set(root["required"] as? [String] ?? []) == ["version", "project"])

        let properties = try #require(root["properties"] as? [String: Any])
        let devices = try #require(properties["devices"] as? [String: Any])
        let device = try #require(devices["additionalProperties"] as? [String: Any])
        let deviceProps = try #require(device["properties"] as? [String: Any])
        #expect(deviceProps.keys.sorted() == ["isolation", "pairWith", "platform", "runtime", "type"])
        let platform = try #require(deviceProps["platform"] as? [String: Any])
        #expect(platform["enum"] as? [String] == ["macOS"])
        let isolation = try #require(deviceProps["isolation"] as? [String: Any])
        #expect(isolation["enum"] as? [String] == ["shared", "suffix"])
    }

    @Test func everyNodeHasADescription() throws {
        func check(_ node: SchemaNode, _ path: String) {
            #expect(!node.summary.isEmpty, "missing description at \(path)")
            switch node {
            case .object(_, let fields): fields.forEach { check($0.node, path + "." + $0.name) }
            case .map(_, let value): check(value, path + ".*")
            default: break
            }
        }
        check(ConfigSchema.v1, "")
    }
}
