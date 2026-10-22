import Foundation

/// `xcd sim open-url`, `push`, `privacy`, `status-bar`, `appearance`, `location`, `pasteboard`, and `addmedia`
///. Each boots the clone, then runs one simctl command.
public struct DeviceStateService: Sendable {
    public let provisioner: DeviceProvisioner
    public let now: @Sendable () -> Date

    public init(provisioner: DeviceProvisioner, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provisioner = provisioner
        self.now = now
    }

    /// Opens a URL in whatever app takes it. When the link's scheme is one this worktree's built app registers, the
    /// scheme is approved first, so no "Open in …?" alert holds the link.
    public func openURL(_ url: String, device: String?, in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        let name = try provisioner.deviceName(device, config: ctx.config)
        let product = (try? AppStateStore.load(ctx.paths))?.builds[name]?.product
        return try await run(name, &ctx, "opened \(url)") { simctl, udid in
            if let product, let scheme = LinkScheme.of(url), !LinkScheme.isWeb(scheme),
               AppSchemes.registers(scheme, in: AppSchemes.registered(by: product) ?? []) {
                try await simctl.approveScheme(udid: udid, scheme: scheme, bundleId: product.bundleId)
            }
            try await simctl.openURL(udid: udid, url: url)
        }
    }

    public func push(alert: String?, file: String?, bundle: String? = nil, device: String? = nil,
                     in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        guard (alert == nil) != (file == nil) else {
            throw XcdError(.usage, "a push needs one payload", next: "pass either --alert <text> or --file <payload.json>")
        }
        if let file, !FileManager.default.fileExists(atPath: file) {
            throw XcdError(.usage, "\(file) doesn't exist", next: "pass a JSON payload file with an \"aps\" key")
        }
        let name = try provisioner.deviceName(device, config: ctx.config)
        let bundleId = try self.bundleId(bundle, device: name, in: ctx)
        let payload = try file ?? alertPayload(alert ?? "", in: ctx)
        return try await run(name, &ctx, "pushed to \(bundleId)") {
            try await $0.push(udid: $1, bundleId: bundleId, payloadFile: payload)
        }
    }

    public func privacy(_ action: PrivacyAction, service: String, bundle: String? = nil, device: String? = nil,
                        in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        let name = try provisioner.deviceName(device, config: ctx.config)
        // reset may name no app (every app); grant and revoke need one.
        let bundleId: String? = action == .reset
            ? bundle ?? (try? AppStateStore.load(ctx.paths))?.builds[name]?.product?.bundleId
            : try self.bundleId(bundle, device: name, in: ctx)
        let summary: String
        switch action {
        case .grant: summary = "granted \(service) to \(bundleId ?? "")"
        case .revoke: summary = "revoked \(service) from \(bundleId ?? "")"
        case .reset: summary = "reset \(service) " + (bundleId.map { "for \($0)" } ?? "for every app")
        }
        return try await run(name, &ctx, summary) {
            try await $0.privacy(udid: $1, action: action, service: service, bundleId: bundleId)
        }
    }

    /// Nil clears the overrides.
    public func statusBar(_ overrides: StatusBarOverrides?, device: String?,
                          in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        guard let overrides else {
            return try await run(device, &ctx, "cleared the status bar") { try await $0.clearStatusBar(udid: $1) }
        }
        _ = try overrides.arguments()                 // invalid values fail before booting
        return try await run(device, &ctx, "set the status bar: \(overrides.summary)") {
            try await $0.overrideStatusBar(udid: $1, overrides)
        }
    }

    public func appearance(_ value: Appearance, device: String?, in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        try await run(device, &ctx, "set appearance to \(value.rawValue)") { try await $0.setAppearance(udid: $1, value) }
    }

    /// Nil clears the simulated location.
    public func location(_ coordinate: Coordinate?, device: String?, in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        try await run(device, &ctx, coordinate.map { "set location to \($0.text)" } ?? "cleared the location") {
            try await $0.setLocation(udid: $1, coordinate)
        }
    }

    /// simctl exits 0 for text the simulator did not keep, so the pasteboard is read back.
    public func setPasteboard(text: String, device: String?, in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-pasteboard-\(UUID().uuidString).txt").path
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let name = try provisioner.deviceName(device, config: ctx.config)
        return try await run(device, &ctx, "set the pasteboard (\(text.count) characters)") { simctl, udid in
            try await simctl.copyText(udid: udid, file: file)
            guard try await simctl.pasteText(udid: udid) == text else { throw await simctl.textNotKept(by: name, udid: udid) }
        }
    }

    public func pasteboard(device: String?, in ctx: inout WorktreeContext) async throws -> PasteboardReport {
        let name = try provisioner.deviceName(device, config: ctx.config)
        let (clone, _) = try await provisioner.boot(name, in: &ctx)
        let text = try await provisioner.simctl(for: ctx).pasteText(udid: clone.udid)
        return PasteboardReport(device: name, udid: clone.udid, text: text, worktree: ctx.state.name)
    }

    public func addMedia(_ files: [String], device: String?, in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        guard !files.isEmpty else { throw XcdError(.usage, "no files given", next: "pass one or more photos or videos") }
        for file in files where !FileManager.default.fileExists(atPath: file) {
            throw XcdError(.usage, "\(file) doesn't exist", next: "pass photos or videos that exist")   // simctl crashes on these
        }
        return try await run(device, &ctx, "added \(files.count) file\(files.count == 1 ? "" : "s") to Photos") {
            try await $0.addMedia(udid: $1, files: files)
        }
    }

    /// Boots `device`'s clone, runs `body` with its simctl and udid, and reports `action`.
    private func run(_ device: String?, _ ctx: inout WorktreeContext, _ action: String,
                     _ body: (SimctlClient, String) async throws -> Void) async throws -> DeviceStateReport {
        let name = try provisioner.deviceName(device, config: ctx.config)
        let (clone, _) = try await provisioner.boot(name, in: &ctx)
        try await body(provisioner.simctl(for: ctx), clone.udid)
        return DeviceStateReport(action: action, device: name, udid: clone.udid, worktree: ctx.state.name)
    }

    /// `--bundle`, else the bundle id of the last build for `device` (on a Mac under `isolation: suffix`, its copy's).
    func bundleId(_ explicit: String?, device: String, in ctx: WorktreeContext) throws -> String {
        if let explicit { return explicit }
        guard let id = try RunService.productIfBuilt(for: device, in: ctx)?.bundleId else {
            throw XcdError(.appNotBuilt, "no app has been built for \(device) in this worktree, so there's no bundle id to use",
                           next: "pass --bundle <id>, or build first with `xcd build --device \(device)`")
        }
        return id
    }

    /// `{"aps":{"alert":…}}` in `.xcdev/results/`, kept so the agent can see what was sent.
    func alertPayload(_ alert: String, in ctx: WorktreeContext) throws -> String {
        let path = ctx.paths.newArtifact(in: ctx.paths.results, kind: "push", ext: "json", now: now())
        try JSONSerialization.data(withJSONObject: ["aps": ["alert": alert]], options: [.sortedKeys])
            .write(to: URL(fileURLWithPath: path))
        return path
    }
}
