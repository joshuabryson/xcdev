public struct DeviceProvisioner: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let discovery: XcodeDiscovery

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, discovery: XcodeDiscovery? = nil) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.discovery = discovery ?? XcodeDiscovery(runner: runner)
    }

    /// `--device` value, else `defaultDevice`, else the only configured device.
    public func deviceName(_ requested: String?, config: XcdevConfig) throws -> String {
        let names = config.allDevices.keys.sorted()
        if let requested {
            guard config.allDevices[requested] != nil else {
                throw XcdError(.deviceUnknown, "no device named '\(requested)' in .xcdev.yml",
                               next: names.isEmpty ? "add a device under `devices:` in .xcdev.yml"
                                                   : "use one of: \(names.joined(separator: ", "))")
            }
            return requested
        }
        if let preferred = config.defaultDevice { return preferred }
        if names.count == 1 { return names[0] }
        throw XcdError(.usage, "no --device given and no defaultDevice in .xcdev.yml",
                       next: names.isEmpty ? "add a device under `devices:` in .xcdev.yml"
                                           : "pass --device <\(names.joined(separator: "|"))> or set defaultDevice")
    }

    /// Resolves the configured Xcode once per worktree and pins it in worktree.json.
    public func ensureXcode(_ ctx: inout WorktreeContext) async throws -> XcodeInstall {
        if let pinned = ctx.state.xcode { return pinned }
        let xcode = try await discovery.resolve(spec: ctx.config.xcode)
        ctx.state.xcode = xcode
        try WorktreeStateStore.save(ctx.state, ctx.paths)
        return xcode
    }

    public func simctl(for ctx: WorktreeContext) -> SimctlClient {
        SimctlClient(runner: runner, developerDir: ctx.state.xcode?.developerDir)
    }

    /// This worktree's clone for `name`, cloning (and pairing) it on first use or if it was deleted.
    public func ensure(_ name: String, in ctx: inout WorktreeContext) async throws -> ProvisionedDevice {
        guard let spec = ctx.config.allDevices[name] else {
            _ = try deviceName(name, config: ctx.config)      // throws device_unknown with suggestions
            throw XcdError(.deviceUnknown, "no device named '\(name)'")
        }
        guard !spec.isMac else {
            throw XcdError(.usage, "device '\(name)' is a macOS device and has no simulator")
        }
        _ = try await ensureXcode(&ctx)
        let simctl = simctl(for: ctx)
        let catalog = try await simctl.catalog()
        if let existing = ctx.state.devices[name], catalog.device(udid: existing.udid)?.isAvailable == true {
            return existing
        }

        var effective = spec
        if let pinned = ctx.state.devices[name] { effective.runtime = pinned.runtimeIdentifier }
        let resolved = try DeviceResolver.resolve(name: name, spec: effective, catalog: catalog)
        let template = try await TemplateStore(simctl: simctl, locksDirectory: globalPaths.locksDirectory)
            .ensureTemplate(for: resolved)
        let cloneName = SimNaming.clone(project: ctx.state.project, worktree: ctx.state.name, device: name)
        for stale in catalog.devices where stale.name == cloneName {
            try? await simctl.delete(udid: stale.udid)
        }
        let udid = try await simctl.clone(udid: template, name: cloneName)
        let device = ProvisionedDevice(udid: udid, deviceType: resolved.deviceType.name,
                                       deviceTypeIdentifier: resolved.deviceType.identifier,
                                       runtime: resolved.runtime.name, runtimeIdentifier: resolved.runtime.identifier)
        ctx.state.devices[name] = device
        try WorktreeStateStore.save(ctx.state, ctx.paths)

        if let partner = spec.pairWith {
            let phone = try await ensure(partner, in: &ctx)
            try await simctl.pair(watch: udid, phone: phone.udid)
        }
        return device
    }

    public func boot(_ name: String, in ctx: inout WorktreeContext) async throws -> (device: ProvisionedDevice, retries: Int) {
        let device = try await ensure(name, in: &ctx)
        let retries = try await simctl(for: ctx).boot(udid: device.udid)
        return (device, retries)
    }
}
