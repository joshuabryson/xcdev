import Foundation

/// Orchestration behind `xcd sim …`, kept in the library so the CLI only parses and wires.
extension DeviceProvisioner {
    public func bootReport(_ requested: String?, in ctx: inout WorktreeContext) async throws -> SimReport {
        let name = try deviceName(requested, config: ctx.config)
        let (device, retries) = try await boot(name, in: &ctx)
        return SimReport(action: "booted", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name)
    }

    public func shutdownReport(_ requested: String?, in ctx: WorktreeContext,
                               detached: (any DetachedProcessLaunching)? = nil) async throws -> SimReport {
        guard let going = try await goingAway(requested, in: ctx, detached) else {
            return notCloned(try deviceName(requested, config: ctx.config), ctx)
        }
        let retries = try await simctl(for: ctx).shutdown(udid: going.device.udid)
        return going.report("shut down", retries: retries, ctx)
    }

    public func eraseReport(_ requested: String?, in ctx: WorktreeContext,
                            detached: (any DetachedProcessLaunching)? = nil) async throws -> SimReport {
        guard let going = try await goingAway(requested, in: ctx, detached) else {
            return notCloned(try deviceName(requested, config: ctx.config), ctx)
        }
        let client = simctl(for: ctx)
        let retries = try await client.shutdown(udid: going.device.udid)
        try await client.erase(udid: going.device.udid)
        return going.report("erased", retries: retries, ctx)
    }

    /// Shuts down every booted simulator clone of the worktree and ends each clone's session. Devices are listed sorted;
    /// a Mac has no simulator and is left out.
    public func shutdownAllReport(in ctx: WorktreeContext,
                                  detached: (any DetachedProcessLaunching)? = nil) async throws -> ShutdownAllReport {
        let catalog = try await simctl(for: ctx).catalog()
        let states = Dictionary(catalog.devices.map { ($0.udid, $0.state) }, uniquingKeysWith: { first, _ in first })
        var devices: [ShutdownAllReport.Device] = []
        for name in ctx.config.allDevices.filter({ !$0.value.isMac }).keys.sorted() {
            devices.append(try await shutdownOne(name, states: states, in: ctx, detached))
        }
        return ShutdownAllReport(devices: devices, worktree: ctx.state.name)
    }

    private func shutdownOne(_ name: String, states: [String: String], in ctx: WorktreeContext,
                             _ detached: (any DetachedProcessLaunching)?) async throws -> ShutdownAllReport.Device {
        guard let device = ctx.state.devices[name] else {
            return .init(device: name, udid: nil, action: "not cloned", retries: 0, notes: [])
        }
        guard states[device.udid] == "Booted" else {
            if let detached {
                await Watchdogs(leases: DeviceLeases(globalPaths: globalPaths), detached: detached).end(device.udid)
            }
            return .init(device: name, udid: device.udid, action: "not booted", retries: 0, notes: [])
        }
        let report = try await shutdownReport(name, in: ctx, detached: detached)
        return .init(device: name, udid: device.udid, action: report.action, retries: report.retries, notes: report.notes)
    }

    /// A clone about to be shut down or erased, with the notes from stopping what ran against it.
    private struct GoingAway {
        let name: String
        let device: ProvisionedDevice
        let notes: [String]

        func report(_ action: String, retries: Int, _ ctx: WorktreeContext) -> SimReport {
            SimReport(action: action, device: name, udid: device.udid, retries: retries, worktree: ctx.state.name, notes: notes)
        }
    }

    /// Nil when the device was never cloned. Otherwise a recording or UI runner of the clone is stopped first, so
    /// simctl finishes the video and the runner's xcodebuild doesn't outlive its simulator.
    private func goingAway(_ requested: String?, in ctx: WorktreeContext,
                           _ detached: (any DetachedProcessLaunching)?) async throws -> GoingAway? {
        let name = try deviceName(requested, config: ctx.config)
        if ctx.config.allDevices[name]?.isMac == true { throw DeviceResolver.macHasNoSimulator(name) }
        guard let device = ctx.state.devices[name] else { return nil }
        var notes: [String] = []
        if let detached {
            notes += await Recordings.stopAll(in: ctx.paths, device: name, detached: detached, now: Date()).map(\.note)
            notes += await Runners.stopAll(in: ctx.paths, device: name, detached: detached)
            await Watchdogs(leases: DeviceLeases(globalPaths: globalPaths), detached: detached).end(device.udid)
        }
        return GoingAway(name: name, device: device, notes: notes)
    }

    public func openReport(_ requested: String?, in ctx: inout WorktreeContext) async throws -> SimReport {
        let name = try deviceName(requested, config: ctx.config)
        let (device, retries) = try await boot(name, in: &ctx)
        let viewer = SimulatorViewer(xcode: try await ensureXcode(&ctx))
        try await simctl(for: ctx).show(udid: device.udid, in: viewer)
        return SimReport(action: "opened", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name,
                         notes: viewer.notes)
    }

    private func notCloned(_ name: String, _ ctx: WorktreeContext) -> SimReport {
        SimReport(action: "not cloned", device: name, udid: nil, retries: 0, worktree: ctx.state.name)
    }
}

extension ContextInfo {
    /// An explicit device must be valid; without one, use the default if there is one, else report no device.
    public static func resolve(ctx: WorktreeContext, requestedDevice: String?, provisioner: DeviceProvisioner,
                               output: OutputFormat? = nil) throws -> ContextInfo {
        let name = requestedDevice != nil
            ? try provisioner.deviceName(requestedDevice, config: ctx.config)
            : try? provisioner.deviceName(nil, config: ctx.config)
        return build(ctx: ctx, device: name, output: output)
    }
}
