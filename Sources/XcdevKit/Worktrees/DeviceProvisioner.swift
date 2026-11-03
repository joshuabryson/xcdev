public struct DeviceProvisioner: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let discovery: XcodeDiscovery
    public let sdks: SDKStore
    /// Begins the idle session of each clone this provisioner boots. Nil leases nothing.
    public let sessions: IdleSessions?

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, discovery: XcodeDiscovery? = nil,
                sessions: IdleSessions? = nil) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.discovery = discovery ?? XcodeDiscovery(runner: runner)
        self.sdks = SDKStore(runner: runner, cacheDirectory: globalPaths.cacheDirectory)
        self.sessions = sessions
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
        if let override = ctx.xcodeOverride { return override }
        if let pinned = ctx.state.xcode { return pinned }
        let xcode = try await discovery.resolve(spec: ctx.config.xcode)
        ctx.state.xcode = xcode
        try WorktreeStateStore.save(ctx.state, ctx.paths)
        return xcode
    }

    public func simctl(for ctx: WorktreeContext) -> SimctlClient {
        SimctlClient(runner: runner, developerDir: ctx.xcode?.developerDir)
    }

    /// The simulator device `name`, or `device_unknown`, or `platform_unsupported` for a Mac.
    private func simulatorSpec(_ name: String, config: XcdevConfig) throws -> DeviceSpec {
        guard let spec = config.allDevices[name] else {
            _ = try deviceName(name, config: config)      // throws device_unknown with suggestions
            throw XcdError(.deviceUnknown, "no device named '\(name)'")
        }
        guard !spec.isMac else {
            throw DeviceResolver.macHasNoSimulator(name)
        }
        return spec
    }

    /// This worktree's clone for `name`, cloning (and pairing) it on first use or if it was deleted.
    public func ensure(_ name: String, in ctx: inout WorktreeContext) async throws -> ProvisionedDevice {
        let spec = try simulatorSpec(name, config: ctx.config)
        let xcode = try await ensureXcode(&ctx)
        let simctl = simctl(for: ctx)
        let catalog = try await simctl.catalog()
        let compatibility = RuntimeCompatibility(xcode: xcode, sdks: try await sdks.sdks(for: xcode))
        if let existing = ctx.state.devices[name], catalog.device(udid: existing.udid)?.isAvailable == true {
            if let runtime = catalog.runtimes.first(where: { $0.identifier == existing.runtimeIdentifier }) {
                try compatibility.check(runtime, device: name, installed: catalog.runtimes,
                                        deviceType: catalog.deviceTypes.first { $0.identifier == existing.deviceTypeIdentifier })
            }
            return try await pairIfNeeded(name, spec: spec, in: &ctx)
        }

        var effective = spec
        if let pinned = ctx.state.devices[name] { effective.runtime = pinned.runtimeIdentifier }
        let resolved = try DeviceResolver.resolve(name: name, spec: effective, catalog: catalog, compatibility: compatibility)
        let template = try await TemplateStore(simctl: simctl, locksDirectory: globalPaths.locksDirectory)
            .ensureTemplate(for: resolved)
        let cloneName = SimNaming.clone(project: ctx.state.project, worktree: ctx.state.name, device: name)
        // Never delete by name: another project with the same basename shares it. Orphans are for `xcd doctor`.
        let udid = try await simctl.clone(udid: template, name: cloneName)
        let device = ProvisionedDevice(udid: udid, deviceType: resolved.deviceType.name, deviceTypeIdentifier: resolved.deviceType.identifier,
                                       runtime: resolved.runtime.name, runtimeIdentifier: resolved.runtime.identifier)
        ctx.state.devices[name] = device
        try WorktreeStateStore.save(ctx.state, ctx.paths)

        return try await pairIfNeeded(name, spec: spec, in: &ctx)
    }

    /// Pairs a watch with its phone until the pairing is recorded, and again if the phone was re-cloned.
    private func pairIfNeeded(_ name: String, spec: DeviceSpec, in ctx: inout WorktreeContext) async throws -> ProvisionedDevice {
        guard let partner = spec.pairWith, let device = ctx.state.devices[name] else {
            return try requireDevice(name, in: ctx)
        }
        let phone = try await ensure(partner, in: &ctx)
        if device.pairedWith != phone.udid {
            try await simctl(for: ctx).pair(watch: device.udid, phone: phone.udid)
            ctx.state.devices[name]?.pairedWith = phone.udid
            try WorktreeStateStore.save(ctx.state, ctx.paths)
        }
        return try requireDevice(name, in: ctx)
    }

    private func requireDevice(_ name: String, in ctx: WorktreeContext) throws -> ProvisionedDevice {
        guard let device = ctx.state.devices[name] else {
            throw XcdError(.internalError, "device '\(name)' was not recorded after provisioning")
        }
        return device
    }

    public func boot(_ name: String, in ctx: inout WorktreeContext) async throws -> (device: ProvisionedDevice, retries: Int) {
        let device = try await ensure(name, in: &ctx)
        let retries = try await simctl(for: ctx).boot(udid: device.udid)
        await leased(name, device, in: ctx)
        return (device, retries)
    }

    /// After a boot: begins or keeps the clone's idle session. A watchdog that could not start becomes a note, never a
    /// failure; this command's `--idle`, when given, is noted too.
    public func leased(_ name: String, _ device: ProvisionedDevice, in ctx: WorktreeContext) async {
        guard let sessions else { return }
        if let note = await sessions.began(name, device, in: ctx, simctl: simctl(for: ctx)) { Notes.current?.add(note) }
        if let idle = ctx.idleOverride { Notes.current?.add("idle \(IdleThreshold.text(idle))") }
    }

    /// For `xcd test`, whose xcodebuild boots the clone itself: `leased` when the worktree's clone `name` is booted now.
    /// A clone never made, or a `simctl list` that fails, leases nothing.
    public func leaseIfBooted(_ name: String, in ctx: WorktreeContext) async {
        guard sessions != nil, let device = ctx.state.devices[name],
              let catalog = try? await simctl(for: ctx).catalog(), catalog.device(udid: device.udid)?.state == "Booted"
        else { return }
        await leased(name, device, in: ctx)
    }
}
