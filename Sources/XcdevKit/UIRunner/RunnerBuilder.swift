import Foundation

/// A built UI runner, ready to start on any simulator.
public struct RunnerBuild: Codable, Sendable, Equatable {
    /// Xcode build + source hash.
    public let key: String
    /// `<cache>/ui-runner/<key>`.
    public let directory: String
    public let xctestrun: String
}

/// Builds the UI runner once per Xcode and runner source, shared by every worktree and project.
public struct RunnerBuilder: Sendable {
    public let runner: any ProcessRunning
    public let globalPaths: GlobalPaths
    public let progress: @Sendable (String) -> Void

    public init(runner: any ProcessRunning, globalPaths: GlobalPaths, progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.runner = runner
        self.globalPaths = globalPaths
        self.progress = progress
    }

    public func key(for xcode: XcodeInstall) -> String { xcode.build + "-" + RunnerSource.hash }

    func directory(for xcode: XcodeInstall) -> String { globalPaths.cacheDirectory + "/ui-runner/" + key(for: xcode) }

    /// Forgets the build for `xcode`, failed or not, so the next use builds again (`xcd ui stop --rebuild`).
    public func discard(xcode: XcodeInstall) async throws {
        let directory = directory(for: xcode)
        try await FileLock.withLock(at: globalPaths.locksDirectory + "/ui-runner-build.lock") {
            if FileManager.default.fileExists(atPath: directory) { try FileManager.default.removeItem(atPath: directory) }
        }
    }

    public func ensureBuilt(xcode: XcodeInstall) async throws -> RunnerBuild {
        let directory = directory(for: xcode)
        if let build = existing(in: directory, xcode: xcode) { return build }
        return try await FileLock.withLock(at: globalPaths.locksDirectory + "/ui-runner-build.lock") {
            if let build = existing(in: directory, xcode: xcode) { return build }      // another xcd built it while we waited
            let log = directory + "/build.log"
            if FileManager.default.fileExists(atPath: directory + "/failed") { throw failure(log: log) }
            try? FileManager.default.removeItem(atPath: directory)
            try RunnerSource.write(to: directory + "/project")
            progress("building UI runner (one-time, about 30s)…")
            let output = try await runXcodebuild(directory: directory, xcode: xcode, log: log)
            let xctestrun = try handleBuildResult(output: output, directory: directory, log: log)
            return RunnerBuild(key: key(for: xcode), directory: directory, xctestrun: xctestrun)
        }
    }

    func runXcodebuild(directory: String, xcode: XcodeInstall, log: String) async throws -> ProcessOutput {
        var invocation = Invocation.xcrun(["xcodebuild", "build-for-testing", "-project", directory + "/project/" + RunnerSource.projectPath,
                                           "-scheme", RunnerSource.scheme, "-destination", "generic/platform=iOS Simulator",
                                           "-derivedDataPath", directory + "/DerivedData"],
                                          developerDir: xcode.developerDir, timeout: .seconds(900))
        invocation.outputFile = log
        do {
            return try await runner.run(invocation)
        } catch let xcErr as XcdError where xcErr.code == .timeout {
            throw XcdError(.runnerFailed, "building the UI runner timed out",
                           next: "run the command again; the first build can be slow on a busy Mac", details: ["log: \(log)"])
        }
    }

    func handleBuildResult(output: ProcessOutput, directory: String, log: String) throws -> String {
        guard output.succeeded else {
            if output.exitCode == 65 {
                markFailed(in: directory)
                throw failure(log: log)
            }
            throw interrupted(exitCode: output.exitCode, log: log)
        }
        guard let xctestrun = Self.xctestrun(in: directory) else {
            markFailed(in: directory)
            throw XcdError(.runnerFailed, "the UI runner built but produced no .xctestrun",
                           next: "read the build log, then run `xcd ui stop --rebuild` to try again", details: ["log: \(log)"])
        }
        guard Self.timeoutsDisabled(xctestrun) else {
            markFailed(in: directory)
            throw XcdError(.runnerFailed, "the UI runner was built with test timeouts on, so XCTest would stop it after 10 minutes",
                           next: "this is a bug in xcd; please report it", details: ["xctestrun: \(xctestrun)"])
        }
        // Written last: a build another xcd is still running has products on disk but no marker.
        let builtPath = directory + "/built"
        guard FileManager.default.createFile(atPath: builtPath, contents: nil) else {
            let cacheDir = globalPaths.cacheDirectory
            throw XcdError(.runnerFailed, "could not record the UI runner build in \(directory)",
                           next: "check that \(cacheDir) is writable and has free space")
        }
        return xctestrun
    }

    func existing(in directory: String, xcode: XcodeInstall) -> RunnerBuild? {
        guard FileManager.default.fileExists(atPath: directory + "/built"),
              let xctestrun = Self.xctestrun(in: directory) else { return nil }
        return RunnerBuild(key: key(for: xcode), directory: directory, xctestrun: xctestrun)
    }

    /// Writes the permanent marker that stops later builds retrying until `discard`.
    func markFailed(in directory: String) {
        try? Data().write(to: URL(fileURLWithPath: directory + "/failed"))
    }

    func interrupted(exitCode: Int32, log: String) -> XcdError {
        let tail = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(20).map(String.init)
        return XcdError(.runnerFailed, "building the UI runner was interrupted or failed to run (exit \(exitCode))",
                        next: "run the command again; if it keeps failing, read the build log", details: ["log: \(log)"] + tail)
    }

    func failure(log: String) -> XcdError {
        let tail = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(20).map(String.init)
        return XcdError(.runnerFailed, "the UI runner failed to build with this Xcode",
                        next: "read the build log, then run `xcd ui stop --rebuild` to try again", details: ["log: \(log)"] + tail)
    }

    /// The .xctestrun in the build's products folder. Its name includes the SDK and architectures, so it is found, not built.
    static func xctestrun(in directory: String) -> String? {
        let products = directory + "/DerivedData/Build/Products"
        return ((try? FileManager.default.contentsOfDirectory(atPath: products)) ?? []).sorted()
            .first { $0.hasSuffix(".xctestrun") }.map { products + "/" + $0 }
    }

    /// Whether every test target in the .xctestrun has `TestTimeoutsEnabled == false`.
    static func timeoutsDisabled(_ xctestrun: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: xctestrun),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let configurations = plist["TestConfigurations"] as? [[String: Any]], !configurations.isEmpty else { return false }
        let targets = configurations.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
        return !targets.isEmpty && targets.allSatisfy { ($0["TestTimeoutsEnabled"] as? Bool) == false }
    }
}
