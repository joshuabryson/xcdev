import Foundation
import IOKit

/// The daemon's envelope for one vendor event, built from a recipe. Pure, so a
/// test can read it back. Every string and number comes from the recipe.
enum VendorEventMessage {
    /// The dictionary locationd reads: provider, source, type, value.
    static func payload(_ request: PostureRequest, _ recipe: DirectRecipe) throws -> [String: Any] {
        switch request {
        case .hinge(let degrees):
            return ["provider": recipe.provider, "source": recipe.hinge.source, "type": recipe.hinge.type, "value": degrees]
        case .orientation(let orientation):
            guard let value = recipe.orientation.values[orientation.rawValue] else { throw recipe.unsupported(orientation) }
            return ["provider": recipe.provider, "source": recipe.orientation.source, "type": recipe.orientation.type,
                    "value": value]
        }
    }

    /// `IndigoVendorDefinedEvent` with a payload of three uint64s and the IOKit-serialized dictionary.
    static func build(_ request: PostureRequest, _ recipe: DirectRecipe) throws -> xpc_object_t {
        let payload = try payload(request, recipe) as CFDictionary
        guard let serialized = IOCFSerialize(payload, CFOptionFlags(kIOCFSerializeToBinary)) else {
            throw VendorEventError(step: "serialize", detail: "IOCFSerialize returned nil for the payload")
        }
        let bytes = serialized as Data
        let event = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(event, "usagePage", recipe.usagePage)
        xpc_dictionary_set_uint64(event, "usage", recipe.usage)
        xpc_dictionary_set_uint64(event, "version", recipe.version)
        xpc_dictionary_set_value(event, "data", bytes.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) })
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "messageType", recipe.messageType)
        xpc_dictionary_set_string(message, "featureIdentifier", recipe.feature)
        xpc_dictionary_set_bool(message, "isBarrier", false)
        xpc_dictionary_set_value(message, "payload", event)
        return message
    }
}

/// A step of the direct route that failed, for `posture_failed`'s details.
struct VendorEventError: Error, Equatable, CustomStringConvertible {
    let step: String
    let detail: String
    var description: String { "direct route, \(step): \(detail)" }
}
