/// Where a build, test, or run happens.
public struct BuildTarget: Sendable, Equatable {
    /// Target name for a Swift package built without any configured device.
    public static let hostName = "host"

    public let name: String
    public let destination: Destination
    /// The worktree's clone, for simulator targets.
    public let device: ProvisionedDevice?

    public init(name: String, destination: Destination, device: ProvisionedDevice?) {
        self.name = name
        self.destination = destination
        self.device = device
    }

    /// The config device name, or nil for a package built for the host.
    public var configDevice: String? { name == Self.hostName ? nil : name }

    public var summary: String {
        guard let device else { return "\(name) (macOS)" }
        return "\(name) (\(device.deviceType), \(device.runtime))"
    }
}

extension DeviceProvisioner {
    /// The target's name without provisioning anything: `host` for a package with no devices, else the device.
    public func targetName(_ requested: String?, container: ProjectContainer, config: XcdevConfig) throws -> String {
        if requested == nil, config.allDevices.isEmpty, container.isPackage { return BuildTarget.hostName }
        return try deviceName(requested, config: config)
    }

    /// The target as an xcodebuild destination, cloning its simulator on first use.
    public func buildTarget(_ requested: String?, container: ProjectContainer,
                            in ctx: inout WorktreeContext) async throws -> BuildTarget {
        let name = try targetName(requested, container: container, config: ctx.config)
        if name == BuildTarget.hostName || ctx.config.allDevices[name]?.isMac == true {
            return BuildTarget(name: name, destination: .macOS, device: nil)
        }
        let device = try await ensure(name, in: &ctx)
        return BuildTarget(name: name, destination: .simulator(udid: device.udid), device: device)
    }
}
