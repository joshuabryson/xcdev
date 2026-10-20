import Foundation

/// Opens the project in Xcode for a person: the .xcworkspace, .xcodeproj, or Package.swift that `project:` names,
/// handed by path to the Xcode this worktree uses, so that with two Xcodes installed Launch Services is never left
/// to pick one.
public struct XcodeOpener: Sendable {
    let runner: any ProcessRunning
    let provisioner: DeviceProvisioner

    public init(runner: any ProcessRunning, provisioner: DeviceProvisioner) {
        self.runner = runner
        self.provisioner = provisioner
    }

    /// The project file is checked before the Xcode is resolved, so a bad `project:` opens nothing and pins nothing.
    /// Nothing is built. `open` hands its own environment to the app it starts (seen on macOS 27), so the Xcode gets
    /// its own DEVELOPER_DIR, not one the caller's shell may have set for another Xcode.
    public func open(in ctx: inout WorktreeContext) async throws -> XcodeOpenReport {
        let container = try ProjectContainer.resolve(config: ctx.config, worktreeRoot: ctx.location.worktreeRoot)
        let xcode = try await provisioner.ensureXcode(&ctx)
        let invocation = Invocation("/usr/bin/open", ["-a", xcode.path, container.fileToOpen],
                                    environment: ["DEVELOPER_DIR": xcode.developerDir])
        _ = try await runner.runChecked(invocation, next: "run \(invocation.commandLine) yourself")
        return XcodeOpenReport(project: ctx.config.project, path: container.fileToOpen, xcode: xcode, worktree: ctx.state.name)
    }
}

extension ProjectContainer {
    /// What Xcode is given: the workspace or project bundle, or a package's manifest.
    var fileToOpen: String {
        switch self {
        case .workspace(let path), .project(let path): path
        case .package(let directory): directory + "/Package.swift"
        }
    }
}

public struct XcodeOpenReport: Reportable {
    /// `project:` as .xcdev.yml names it.
    public let project: String
    /// The file handed to Xcode.
    public let path: String
    public let xcode: XcodeInstall
    public let worktree: String

    public init(project: String, path: String, xcode: XcodeInstall, worktree: String) {
        self.project = project
        self.path = path
        self.xcode = xcode
        self.worktree = worktree
    }

    public var text: String { "opened \(project) in \(xcode.summary)" }
    public var envelopeWorktree: String? { worktree }
}
