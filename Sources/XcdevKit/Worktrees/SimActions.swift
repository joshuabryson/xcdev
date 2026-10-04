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
        let name = try deviceName(requested, config: ctx.config)
        guard let device = ctx.state.devices[name] else { return notCloned(name, ctx) }
        let notes = await stopRecording(name, ctx, detached)
        let retries = try await simctl(for: ctx).shutdown(udid: device.udid)
        return SimReport(action: "shut down", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name, notes: notes)
    }

    public func eraseReport(_ requested: String?, in ctx: WorktreeContext,
                            detached: (any DetachedProcessLaunching)? = nil) async throws -> SimReport {
        let name = try deviceName(requested, config: ctx.config)
        guard let device = ctx.state.devices[name] else { return notCloned(name, ctx) }
        let notes = await stopRecording(name, ctx, detached)
        let client = simctl(for: ctx)
        let retries = try await client.shutdown(udid: device.udid)
        try await client.erase(udid: device.udid)
        return SimReport(action: "erased", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name, notes: notes)
    }

    /// A recording of a clone that is going away is stopped first, so simctl finishes the video.
    private func stopRecording(_ name: String, _ ctx: WorktreeContext, _ detached: (any DetachedProcessLaunching)?) async -> [String] {
        guard let detached else { return [] }
        return await Recordings.stopAll(in: ctx.paths, device: name, detached: detached, now: Date()).map(\.note)
    }

    public func openReport(_ requested: String?, in ctx: inout WorktreeContext) async throws -> SimReport {
        let name = try deviceName(requested, config: ctx.config)
        let (device, retries) = try await boot(name, in: &ctx)
        try await simctl(for: ctx).openSimulatorApp(udid: device.udid)
        return SimReport(action: "opened", device: name, udid: device.udid, retries: retries, worktree: ctx.state.name)
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
