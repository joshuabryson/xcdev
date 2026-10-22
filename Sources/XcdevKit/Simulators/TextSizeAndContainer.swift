import Foundation

/// `xcd sim text-size` and `xcd sim container`: the device's text size, and where an installed app's
/// files are on this Mac.
extension SimctlClient {
    /// The sizes `simctl ui content_size` takes, smallest first: the Dynamic Type sizes, then the larger accessibility ones.
    public static let textSizes = ["extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
                                   "accessibility-medium", "accessibility-large", "accessibility-extra-large",
                                   "accessibility-extra-extra-large", "accessibility-extra-extra-extra-large"]

    public func setTextSize(udid: String, _ size: String) async throws {
        try await runner.runChecked(simctl(["ui", udid, "content_size", size]), code: .simulatorFailed, next: "run `xcd doctor`")
    }

    /// The device's text size by the name simctl takes for it; `unsupported` or `unknown` when simctl can't say.
    /// simctl prints two of the names with a capital it does not ask for (`extra-Small`, `Small`; seen on Xcode 27.0).
    public func textSize(udid: String) async throws -> String {
        try await runner.runChecked(simctl(["ui", udid, "content_size"]), code: .simulatorFailed, next: "run `xcd doctor`")
            .stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// What simctl prints for one of an installed app's containers: a path on this Mac for `data`, `app`, or an app
    /// group's identifier; for `groups`, a line per app group with its identifier, a tab, and its path.
    public func container(udid: String, bundleId: String, _ container: String) async throws -> String {
        let invocation = simctl(["get_app_container", udid, bundleId, container])
        let out = try await runner.run(invocation)
        if out.succeeded { return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) }
        let named = ["data", "app", "groups"].contains(container)
        throw XcdError.subprocess(
            invocation, out, code: .simulatorFailed, message: "the simulator has no \(container) container for \(bundleId)",
            next: named ? "install the app on this clone first (`xcd install` or `xcd run`), or name another app with --bundle <id>"
                        : "the app must be installed on this clone (`xcd install` or `xcd run`) and have that app group; "
                            + "`xcd sim container groups` lists the groups it has")
    }
}

extension DeviceStateService {
    /// Sets the text size (the Dynamic Type size); nil reads it. Either way the report has the size the device says it has.
    public func textSize(_ size: String?, device: String?, in ctx: inout WorktreeContext) async throws -> TextSizeReport {
        if let size, !SimctlClient.textSizes.contains(size) {                // a size simctl doesn't know fails before booting
            throw XcdError(.usage, "'\(size)' is not a text size", next: "use one of: " + SimctlClient.textSizes.joined(separator: ", "))
        }
        let name = try provisioner.deviceName(device, config: ctx.config)
        let (clone, _) = try await provisioner.boot(name, in: &ctx)
        let simctl = provisioner.simctl(for: ctx)
        if let size { try await simctl.setTextSize(udid: clone.udid, size) }
        let current = try await simctl.textSize(udid: clone.udid)
        return TextSizeReport(size: current, changed: size != nil, device: name, udid: clone.udid, worktree: ctx.state.name)
    }

    /// Where one of an installed app's containers is on this Mac: `data` (when nil), `app`, an app group's
    /// identifier, or `groups` for every app group's. A Mac device has only `data`, and boots nothing.
    public func container(_ container: String?, bundle: String?, device: String?, in ctx: inout WorktreeContext) async throws -> ContainerReport {
        let name = try provisioner.deviceName(device, config: ctx.config)
        if ctx.config.allDevices[name]?.isMac == true { return try macContainer(container, bundle: bundle, device: name, in: ctx) }
        let bundleId = try self.bundleId(bundle, device: name, in: ctx)
        let kind = container ?? "data"
        let (clone, _) = try await provisioner.boot(name, in: &ctx)
        let answer = try await provisioner.simctl(for: ctx).container(udid: clone.udid, bundleId: bundleId, kind)
        var groups: [String: String]?
        if kind == "groups" {
            let lines = answer.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 1).map(String.init) }
            groups = Dictionary(lines.filter { $0.count == 2 }.map { ($0[0], $0[1]) }) { first, _ in first }
        }
        return ContainerReport(device: name, udid: clone.udid, bundleId: bundleId, container: kind, path: groups == nil ? answer : nil,
                               groups: groups, worktree: ctx.state.name)
    }

    /// `sim container` on a Mac device: the app's one container, from the build's entitlements. The bundle id
    /// is the device's product's, so the copy's under `isolation: suffix`; the entitlements are the build's, which the
    /// copy keeps, so this answers before a launch has made the copy.
    func macContainer(_ kind: String?, bundle: String?, device name: String, in ctx: WorktreeContext) throws -> ContainerReport {
        if bundle != nil {
            throw XcdError(.usage, "on a Mac, `sim container` reads the built app's entitlements; leave --bundle out",
                           next: "run it without --bundle, or look under ~/Library/Containers/<id>/Data yourself")
        }
        if let kind, kind != "data" {
            throw XcdError(.usage, "a Mac app has one container, its data; `\(kind)` is for a simulator",
                           next: "run `xcd sim container --device \(name)` without naming a container")
        }
        let bundleId = try RunService.product(for: name, requested: name, in: ctx).bundleId
        let built = try RunService.recordedProduct(for: name, requested: name, in: ctx)
        let path = try MacContainer.path(bundleId: bundleId, built: built, reader: bundleReader, home: NSHomeDirectory())
        return ContainerReport(device: name, udid: nil, bundleId: bundleId, container: "data", path: path, groups: nil,
                               worktree: ctx.state.name)
    }
}
