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
        let query = Invocation("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(Self.bundleIdentifier)'"],
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

    /// Why `pinned` no longer stands for the `xcode:` spec it was resolved from, or nil while it does or when xcd can't
    /// tell: the Xcode at its path was updated in place, or, with no `xcode:` (or "system"), xcode-select points to
    /// another Xcode. Command Line Tools selected say nothing: "system" resolved to the newest stable Xcode then.
    public func staleness(of pinned: XcodeInstall, spec: String?) async -> String? {
        if let now = await installNow(at: pinned.path), now.build != pinned.build {
            return "\(pinned.path) is now Xcode \(now.version) (\(now.build))"
        }
        let followsSelect = spec.map { $0.trimmingCharacters(in: .whitespaces).lowercased() == "system" } ?? true
        let developer = "/Contents/Developer"
        guard followsSelect, let selected = await selectedDeveloperDir(), selected.hasSuffix(".app" + developer),
              selected != pinned.path, !selected.hasPrefix(pinned.path + "/") else { return nil }
        return "xcode-select points to \(selected.dropLast(developer.count))"
    }

    /// The Xcode at `path` as it is now, from its version.plist; nil when that can't be read. Through the runner, not
    /// read directly as `readInstall` does, so that tests say what is installed at a pinned path.
    func installNow(at path: String) async -> XcodeInstall? {
        let plist = path + "/Contents/version.plist"
        guard let out = try? await runner.run(Invocation("/usr/bin/plutil", ["-convert", "json", "-o", "-", plist], timeout: .seconds(10))),
              out.succeeded,
              let info = (try? JSONSerialization.jsonObject(with: out.stdout)) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              let build = info["ProductBuildVersion"] as? String else { return nil }
        return XcodeInstall(path: path, version: version, build: build)
    }

    public static let bundleIdentifier = "com.apple.dt.Xcode"

    /// Nil unless `path` is an Xcode: the /Applications scan also matches apps such as Xcodes.app, a version manager.
    public static func readInstall(atPath path: String) -> XcodeInstall? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        let build = NSDictionary(contentsOfFile: path + "/Contents/version.plist")?["ProductBuildVersion"] as? String
        return XcodeInstall(path: path, version: version, build: build ?? "unknown")
    }
}
