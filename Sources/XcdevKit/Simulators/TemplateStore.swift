/// Never-booted simulators owned by xcd, used only as clone sources. Creating one is locked per
/// (device type, runtime) so concurrent first uses create exactly one.
public struct TemplateStore: Sendable {
    public let simctl: SimctlClient
    public let locksDirectory: String

    public init(simctl: SimctlClient, locksDirectory: String) {
        self.simctl = simctl
        self.locksDirectory = locksDirectory
    }

    public func ensureTemplate(for resolved: ResolvedDevice) async throws -> String {
        let name = SimNaming.template(resolved)
        let key = resolved.deviceType.identifier + "_" + resolved.runtime.identifier
        let lockPath = locksDirectory + "/template-" + String(key.map { $0.isLetter || $0.isNumber ? $0 : "-" }) + ".lock"
        return try await FileLock.withLock(at: lockPath) {
            let catalog = try await simctl.catalog()
            if let existing = catalog.devices.first(where: { $0.name == name && $0.isAvailable }) {
                return existing.udid
            }
            return try await simctl.create(name: name, type: resolved.deviceType, runtime: resolved.runtime)
        }
    }
}
