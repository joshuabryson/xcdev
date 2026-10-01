import Foundation

public struct XcodeDiscovery: Sendable {
    public let runner: any ProcessRunning
    public let applicationsDirectories: [String]

    public init(runner: any ProcessRunning, applicationsDirectories: [String] = ["/Applications"]) {
        self.runner = runner
        self.applicationsDirectories = applicationsDirectories
    }

    /// Installed Xcodes, newest first. Spotlight plus a scan of Xcode*.app in the applications directories.
    public func installs() async -> [XcodeInstall] {
        var paths: [String] = []
        let query = Invocation("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"],
                               timeout: .seconds(10))
        if let spotlight = try? await runner.run(query), spotlight.succeeded {
            paths += spotlight.stdoutString.split(separator: "\n").map(String.init)
        }
        for directory in applicationsDirectories {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            paths += entries.filter { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }.map { directory + "/" + $0 }
        }
        var seen = Set<String>()
        return paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { seen.insert($0).inserted }
            .compactMap(Self.readInstall(atPath:))
            .sorted { (Version($0.version) ?? .zero) > (Version($1.version) ?? .zero) }
    }

    public func selectedDeveloperDir() async -> String? {
        guard let out = try? await runner.run(Invocation("/usr/bin/xcode-select", ["-p"], timeout: .seconds(10))),
              out.succeeded else { return nil }
        return out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func resolve(spec: String?) async throws -> XcodeInstall {
        var all = await installs()
        var resolveSpec = spec
        if let spec, spec.hasPrefix("/") {
            let normalizedPath = URL(fileURLWithPath: spec).standardizedFileURL.path
            if !all.contains(where: { $0.path == normalizedPath }),
               let explicit = Self.readInstall(atPath: normalizedPath) {
                all.append(explicit)
            }
            resolveSpec = normalizedPath
        }
        return try XcodeResolver.resolve(spec: resolveSpec, installs: all, selectedDeveloperDir: await selectedDeveloperDir())
    }

    public static func readInstall(atPath path: String) -> XcodeInstall? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        let build = NSDictionary(contentsOfFile: path + "/Contents/version.plist")?["ProductBuildVersion"] as? String
        return XcodeInstall(path: path, version: version, build: build ?? "unknown")
    }
}
