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
        let (xcode, problems) = await xcodeProblems(config, project, env)
        guard let catalog = env.catalog else { return problems }
        let compatibility = await compatibility(with: xcode, env)
        return problems + deviceProblems(config, project, catalog: catalog, compatibility: compatibility)
    }

    /// The Xcode the devices are checked against (the pin while it stands, else what `xcode:` resolves to), and what is
    /// wrong with either.
    func xcodeProblems(_ config: XcdevConfig, _ project: DoctorProject, _ env: DoctorEnvironment) async -> (XcodeInstall?, [DoctorProblem]) {
        var problems: [DoctorProblem] = []
        var xcode: XcodeInstall?
        do {
            xcode = try await env.discovery.resolve(spec: config.xcode)
        } catch let error as XcdError {
            problems.append(problem(error))
        } catch {}
        if let pinned = project.state?.xcode {
            if let wrong = await Self.whyWrong(pinned, spec: config.xcode, env) {
                problems.append(DoctorProblem(
                    check: id, message: "worktree '\(project.state?.name ?? "?")' is pinned to \(pinned.summary)" + wrong,
                    action: .unpinXcode, fix: "unpin it, so the next command resolves `xcode:` again",
                    subject: project.location.worktreeRoot))
            } else {
                xcode = pinned
            }
        }
        return (xcode, problems)
    }

    /// ", which is no longer installed" or ", but <why>" once `pinned` no longer stands for `spec`
    /// (`XcodeDiscovery.staleness`); nil while it does.
    static func whyWrong(_ pinned: XcodeInstall, spec: String?, _ env: DoctorEnvironment) async -> String? {
        guard Disk.exists(pinned.path) else { return ", which is no longer installed" }
        return await env.discovery.staleness(of: pinned, spec: spec).map { ", but " + $0 }
    }

    /// What `xcode`'s simulator SDKs allow; nil without an Xcode or when its SDKs can't be read. The one thing a plain
    /// `doctor` may write: SDKStore caches `-showsdks` under <home>/cache.
    func compatibility(with xcode: XcodeInstall?, _ env: DoctorEnvironment) async -> RuntimeCompatibility? {
        guard let xcode,
              let sdks = try? await SDKStore(runner: env.runner, cacheDirectory: env.globalPaths.cacheDirectory).sdks(for: xcode)
        else { return nil }
        return RuntimeCompatibility(xcode: xcode, sdks: sdks)
    }

    /// Each simulator device that does not resolve to an installed type and runtime, its clone's runtime kept.
    func deviceProblems(_ config: XcdevConfig, _ project: DoctorProject, catalog: SimCatalog,
                        compatibility: RuntimeCompatibility?) -> [DoctorProblem] {
        config.allDevices.sorted(by: { $0.key < $1.key }).filter { !$0.value.isMac }.compactMap { name, spec in
            var effective = spec
            if let pinned = project.state?.devices[name] { effective.runtime = pinned.runtimeIdentifier }
            do {
                _ = try DeviceResolver.resolve(name: name, spec: effective, catalog: catalog, compatibility: compatibility)
                return nil
            } catch let error as XcdError {
                return problem(error)
            } catch {
                return nil
            }
        }
    }

    /// Unpins only the Xcode `detect` saw, and only while it is still missing or stale: the worktree may have been
    /// re-pinned since.
    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) async throws {
        guard problem.action == .unpinXcode, let root = problem.subject,
              var state = try WorktreeStateStore.load(WorktreePaths(root: root)), let pinned = state.xcode else { return }
        guard pinned == env.project?.state?.xcode, await Self.whyWrong(pinned, spec: env.project?.config?.xcode, env) != nil else {
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
