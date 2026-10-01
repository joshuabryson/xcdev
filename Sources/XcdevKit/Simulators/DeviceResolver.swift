public struct ResolvedDevice: Sendable, Equatable {
    public let deviceType: SimDeviceType
    public let runtime: SimRuntime
}

public enum DeviceResolver {
    public static func resolve(name: String, spec: DeviceSpec, catalog: SimCatalog,
                               compatibility: RuntimeCompatibility? = nil) throws -> ResolvedDevice {
        guard let typeQuery = spec.type, !spec.isMac else {
            throw XcdError(.usage, "device '\(name)' is a macOS device and has no simulator")
        }
        guard let type = catalog.deviceTypes.first(where: {
            $0.name.caseInsensitiveCompare(typeQuery) == .orderedSame || $0.identifier == typeQuery
        }) else {
            let suggestions = Suggest.closest(to: typeQuery, in: catalog.deviceTypes.map(\.name))
            throw XcdError(.deviceTypeUnknown, "device type '\(typeQuery)' (devices.\(name).type) is not available",
                           next: suggestions.isEmpty
                               ? "run `xcrun simctl list devicetypes` and set devices.\(name).type"
                               : "set devices.\(name).type to one of: \(suggestions.joined(separator: ", "))")
        }
        guard let platform = type.productFamily.flatMap(SimPlatform.init(productFamily:)) else {
            throw XcdError(.deviceTypeUnknown, "cannot tell which platform '\(type.name)' belongs to")
        }

        let candidates = catalog.runtimes.filter { $0.isAvailable && $0.platform == platform.runtimePlatform }
        let query = spec.runtime ?? "latest"
        let runtime: SimRuntime?
        if query.lowercased() == "latest" {
            let supported = candidates.filter { $0.supports(type) }
            let usable = compatibility.map { c in supported.filter { c.sdks.supports($0) } } ?? supported
            runtime = usable.max { (Version($0.version) ?? .zero) < (Version($1.version) ?? .zero) }
            if runtime == nil, let compatibility,
               let newest = supported.max(by: { (Version($0.version) ?? .zero) < (Version($1.version) ?? .zero) }) {
                throw compatibility.mismatch(newest, device: name, installed: catalog.runtimes, deviceType: type)
            }
        } else {
            runtime = candidates.first {
                $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.version == query || $0.identifier == query
            }
        }
        let installed = candidates.map { "installed: \($0.name)" }
        guard let runtime else {
            throw XcdError(.runtimeMissing, "no installed \(platform.rawValue) runtime matches '\(query)' for \(type.name)",
                           next: "xcodebuild -downloadPlatform \(platform.rawValue)", details: installed)
        }
        guard runtime.supports(type) else {
            throw XcdError(.runtimeMissing, "\(runtime.name) does not support \(type.name)",
                           next: "set devices.\(name).runtime to \"latest\" or a runtime that supports \(type.name)",
                           details: installed)
        }
        try compatibility?.check(runtime, device: name, installed: catalog.runtimes, deviceType: type)
        return ResolvedDevice(deviceType: type, runtime: runtime)
    }
}
