import Foundation

/// An executable named `xcd-<name>` on PATH, run as `xcd <name>`.
public struct Plugin: Codable, Sendable, Equatable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct PluginFinder: Sendable {
    public static let prefix = "xcd-"
    /// PATH directories, in order.
    public let directories: [String]

    public init(environment: [String: String]) {
        directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    /// Every plugin, sorted by name. When two PATH directories have the same plugin, the earlier one wins, as in a shell.
    public func plugins() -> [Plugin] {
        let fm = FileManager.default
        var found: [String: Plugin] = [:]
        for directory in directories {
            let entries = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
            for entry in entries.sorted() where entry.hasPrefix(Self.prefix) && entry.count > Self.prefix.count {
                let name = String(entry.dropFirst(Self.prefix.count))
                let path = directory + "/" + entry
                var isDirectory: ObjCBool = false
                guard found[name] == nil, fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      fm.isExecutableFile(atPath: path) else { continue }
                found[name] = Plugin(name: name, path: path)
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }

    public func plugin(named name: String) -> Plugin? { plugins().first { $0.name == name } }
}

/// Runs plugins: `--xcd-describe` for `xcd help`, and the plugin itself for `xcd <name>`.
/// Finding plugins (`PluginFinder`) never executes anything; only `describe` and `run` do.
public struct PluginRunner: Sendable {
    public let runner: any ProcessRunning
    public let describeTimeout: Duration
    public let timeout: Duration

    public init(runner: any ProcessRunning, describeTimeout: Duration = .seconds(3), timeout: Duration = .seconds(1800)) {
        self.runner = runner
        self.describeTimeout = describeTimeout
        self.timeout = timeout
    }

    /// Each plugin's one-line description from `<plugin> --xcd-describe`, asked concurrently. A plugin that
    /// fails, prints nothing, or takes longer than `describeTimeout` has none. Output is captured and stdin is
    /// /dev/null (a non-passthrough run), so a plugin that ignores the flag can't read or write the terminal.
    public func describe(_ plugins: [Plugin]) async -> [String: String] {
        await withTaskGroup(of: (String, String?).self) { group in
            for plugin in plugins {
                group.addTask {
                    let invocation = Invocation(plugin.path, ["--xcd-describe"], timeout: describeTimeout)
                    guard let out = try? await runner.run(invocation), out.succeeded else { return (plugin.name, nil) }
                    let line = out.stdoutString.split(separator: "\n").first
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    return (plugin.name, line?.isEmpty == false ? line : nil)
                }
            }
            var descriptions: [String: String] = [:]
            for await (name, description) in group {
                if let description { descriptions[name] = description }
            }
            return descriptions
        }
    }

    /// Runs the plugin with `arguments`, sharing xcd's stdin, stdout, and stderr. Returns its exit code.
    public func run(_ plugin: Plugin, arguments: [String], environment: [String: String],
                    workingDirectory: String) async throws -> Int32 {
        fflush(stdout)    // anything xcd printed before the plugin must not land after the plugin's output
        return try await runner.run(Invocation(plugin.path, arguments, environment: environment,
                                               workingDirectory: workingDirectory, timeout: timeout, passthrough: true)).exitCode
    }
}
