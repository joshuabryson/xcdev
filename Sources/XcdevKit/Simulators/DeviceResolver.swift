public struct ResolvedDevice: Sendable, Equatable {
    public let deviceType: SimDeviceType
    public let runtime: SimRuntime
}

public enum DeviceResolver {
    /// The one refusal of a `sim` command on a Mac device.
    public static func macHasNoSimulator(_ name: String) -> XcdError {
        XcdError(.platformUnsupported, "device '\(name)' is a macOS device and has no simulator",
                 next: "a Mac app is driven with `xcd ui …` after `xcd run --device \(name)`, and shown to a person with "
                     + "`xcd launch --device \(name) --show`; for a simulator, pass --device with a simulator device")
    }

    public static func resolve(name: String, spec: DeviceSpec, catalog: SimCatalog,
                               compatibility: RuntimeCompatibility? = nil) throws -> ResolvedDevice {
        guard let typeQuery = spec.type, !spec.isMac else { throw macHasNoSimulator(name) }
        let type = try deviceType(typeQuery, of: name, in: catalog)
        guard let platform = type.productFamily.flatMap(SimPlatform.init(productFamily:)) else {
            throw XcdError(.deviceTypeUnknown, "cannot tell which platform '\(type.name)' belongs to")
        }

        let candidates = catalog.runtimes.filter { $0.isAvailable && $0.platform == platform.runtimePlatform }
        let query = spec.runtime ?? "latest"
        let runtime = pick(query, from: candidates, for: type, compatibility: compatibility)
        if runtime == nil, query.lowercased() == "latest", let compatibility, let newest = newest(of: candidates, for: type) {
            throw compatibility.mismatch(newest, device: name, installed: catalog.runtimes, deviceType: type)
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

    private static func deviceType(_ typeQuery: String, of name: String, in catalog: SimCatalog) throws -> SimDeviceType {
        guard let type = catalog.deviceTypes.first(where: {
            $0.name.caseInsensitiveCompare(typeQuery) == .orderedSame || $0.identifier == typeQuery
        }) else {
            let suggestions = Suggest.closest(to: typeQuery, in: catalog.deviceTypes.map(\.name))
            throw XcdError(.deviceTypeUnknown, "device type '\(typeQuery)' (devices.\(name).type) is not available",
                           next: suggestions.isEmpty
                               ? "run `xcrun simctl list devicetypes` and set devices.\(name).type"
                               : "set devices.\(name).type to one of: \(suggestions.joined(separator: ", "))")
        }
        return type
    }

    /// The runtime `query` names ("latest" is the newest that supports the type and the installed SDK), or nil.
    private static func pick(_ query: String, from candidates: [SimRuntime], for type: SimDeviceType,
                             compatibility: RuntimeCompatibility?) -> SimRuntime? {
        if query.lowercased() == "latest" {
            let supported = candidates.filter { $0.supports(type) }
            return (compatibility.map { c in supported.filter { c.sdks.supports($0) } } ?? supported).max(by: older)
        }
        return candidates.first {
            $0.name.caseInsensitiveCompare(query) == .orderedSame || $0.version == query || $0.identifier == query
        }
    }

    /// The newest runtime that supports the type, whether or not the installed SDK can use it.
    private static func newest(of candidates: [SimRuntime], for type: SimDeviceType) -> SimRuntime? {
        candidates.filter { $0.supports(type) }.max(by: older)
    }

    private static func older(_ a: SimRuntime, _ b: SimRuntime) -> Bool { (Version(a.version) ?? .zero) < (Version(b.version) ?? .zero) }
}
