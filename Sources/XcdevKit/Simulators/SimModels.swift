import Foundation

public struct SimDeviceType: Codable, Sendable, Equatable {
    public let name: String
    public let identifier: String
    public let productFamily: String?
}

public struct SimRuntime: Codable, Sendable, Equatable {
    public let name: String
    public let identifier: String
    public let version: String
    public let platform: String?
    public let isAvailable: Bool
    public let supportedDeviceTypes: [SupportedType]?

    public struct SupportedType: Codable, Sendable, Equatable {
        public let identifier: String
    }

    /// Runtimes that don't list supported types are assumed to support everything on their platform.
    public func supports(_ type: SimDeviceType) -> Bool {
        supportedDeviceTypes?.contains { $0.identifier == type.identifier } ?? true
    }
}

public struct SimDevice: Codable, Sendable, Equatable {
    public let udid: String
    public let name: String
    public let state: String
    public let isAvailable: Bool
    public let deviceTypeIdentifier: String?
    /// Not in simctl's per-device JSON; filled in from the enclosing runtime key.
    public var runtimeIdentifier: String?
    /// `~/Library/Developer/CoreSimulator/Devices/<udid>/data`; its parent folder is the device.
    public var dataPath: String?
    /// Bytes simctl reports for `dataPath`.
    public var dataPathSize: Int64?

    /// The device's folder, whose creation date is when the device was created or cloned.
    public var deviceDirectory: String? { dataPath.map { ($0 as NSString).deletingLastPathComponent } }
}

public struct SimCatalog: Sendable, Equatable {
    public let deviceTypes: [SimDeviceType]
    public let runtimes: [SimRuntime]
    public let devices: [SimDevice]

    public static func decode(_ data: Data) throws -> SimCatalog {
        struct Raw: Decodable {
            let devicetypes: [SimDeviceType]
            let runtimes: [SimRuntime]
            let devices: [String: [SimDevice]]
        }
        do {
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            let devices = raw.devices.flatMap { runtime, list in
                list.map { device -> SimDevice in
                    var tagged = device
                    tagged.runtimeIdentifier = runtime
                    return tagged
                }
            }.sorted { $0.name < $1.name }
            return SimCatalog(deviceTypes: raw.devicetypes, runtimes: raw.runtimes, devices: devices)
        } catch {
            throw XcdError(.simulatorFailed, "could not parse `simctl list -j` output",
                           next: "run `xcrun simctl list -j` to check CoreSimulator is healthy",
                           details: ["\(error)"])
        }
    }

    public func device(udid: String) -> SimDevice? { devices.first { $0.udid == udid } }
}
