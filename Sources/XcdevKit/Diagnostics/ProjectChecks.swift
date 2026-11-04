import Foundation

/// The current project's setup: .xcdev.yml is valid, its Xcode is installed, the worktree's pinned Xcode still
/// exists and stands for `xcode:`, and every simulator device resolves to an installed type and runtime. Reported,
/// never installed.
public struct ProjectCheck: DoctorCheck {
    public let id = "project"
    public init() {}

    public func applies(_ env: DoctorEnvironment) -> Bool { env.project != nil }

    public func detect(_ env: DoctorEnvironment) async -> [DoctorProblem] {
        guard let project = env.project else { return [] }
        guard let config = project.config else {
            return project.configError.map { [problem($0)] } ?? []
        }
        var problems: [DoctorProblem] = []
        var xcode: XcodeInstall?
        do {
            xcode = try await env.discovery.resolve(spec: config.xcode)
        } catch let error as XcdError {
            problems.append(problem(error))
        } catch {}
        if let pinned = project.state?.xcode {
            let worktree = "worktree '\(project.state?.name ?? "?")' is pinned to \(pinned.summary)"
            if !FileManager.default.fileExists(atPath: pinned.path) {
                problems.append(unpin(worktree + ", which is no longer installed", project))
            } else if let why = await env.discovery.staleness(of: pinned, spec: config.xcode) {
                problems.append(unpin(worktree + ", but " + why, project))
            } else {
                xcode = pinned
            }
        }
        guard let catalog = env.catalog else { return problems }
        var compatibility: RuntimeCompatibility?
        // The one thing a plain `doctor` may write: SDKStore caches `-showsdks` under <home>/cache.
        if let xcode, let sdks = try? await SDKStore(runner: env.runner, cacheDirectory: env.globalPaths.cacheDirectory).sdks(for: xcode) {
            compatibility = RuntimeCompatibility(xcode: xcode, sdks: sdks)
        }
        for (name, spec) in config.allDevices.sorted(by: { $0.key < $1.key }) where !spec.isMac {
            var effective = spec
            if let pinned = project.state?.devices[name] { effective.runtime = pinned.runtimeIdentifier }
            do {
                _ = try DeviceResolver.resolve(name: name, spec: effective, catalog: catalog, compatibility: compatibility)
            } catch let error as XcdError {
                problems.append(problem(error))
            } catch {}
        }
        return problems
    }

    func unpin(_ message: String, _ project: DoctorProject) -> DoctorProblem {
        DoctorProblem(check: id, message: message, action: .unpinXcode, fix: "unpin it, so the next command resolves `xcode:` again",
                      subject: project.location.worktreeRoot)
    }

    /// Unpins only the Xcode `detect` saw, and only while it is still missing or stale: the worktree may have been
    /// re-pinned since.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard problem.action == .unpinXcode, let root = problem.subject,
              var state = try WorktreeStateStore.load(WorktreePaths(root: root)), let pinned = state.xcode else { return }
        let stillWrong = if !FileManager.default.fileExists(atPath: pinned.path) { true } else {
            await env.discovery.staleness(of: pinned, spec: env.project?.config?.xcode) != nil
        }
        guard pinned == env.project?.state?.xcode, stillWrong else {
            throw DoctorLeftAlone(note: "worktree '\(state.name)' is now pinned to \(pinned.summary); left alone")
        }
        state.xcode = nil
        try WorktreeStateStore.save(state, WorktreePaths(root: root))
    }

    func problem(_ error: XcdError) -> DoctorProblem {
        let details = error.details.filter { !$0.hasPrefix("installed: ") && !$0.hasPrefix("compatible with") }
        let message = error.message + (details.isEmpty ? "" : ": " + details.joined(separator: "; "))
        return DoctorProblem(check: id, message: "\(message) (\(error.code.rawValue))", next: error.next)
    }
}
