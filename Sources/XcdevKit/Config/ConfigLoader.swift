import Foundation
import Yams

public enum ConfigLoader {
    public static let fileName = ".xcdev.yml"
    public static let localFileName = ".xcdev.local.yml"

    public static func parse(main: String, local: String? = nil) throws -> XcdevConfig {
        let mainNode = try compose(main, file: fileName)
        var node = mainNode

        // Validate and merge local file separately to attribute errors correctly
        if let local {
            let localNode = try compose(local, file: localFileName)
            let localIssues = SchemaValidator.validate(localNode, against: ConfigSchema.v1, checkRequired: false)
            guard localIssues.isEmpty else { throw invalid(localIssues, file: localFileName) }
            node = NodeMerge.merge(mainNode, localNode)
        }

        let structural = SchemaValidator.validate(node, against: ConfigSchema.v1)
        guard structural.isEmpty else { throw invalid(structural, file: local != nil ? "\(fileName) + \(localFileName)" : fileName) }

        let config: XcdevConfig
        do {
            config = try YAMLDecoder().decode(XcdevConfig.self, from: node)
        } catch {
            throw XcdError(.configInvalid, "\(fileName) could not be decoded", details: ["\(error)"])
        }
        let semantic = semanticIssues(config)
        guard semantic.isEmpty else { throw invalid(semantic, file: local != nil ? "\(fileName) + \(localFileName)" : fileName) }
        return config
    }

    /// Reads `.xcdev.yml` from the worktree checkout (it is versioned with the branch) and
    /// `.xcdev.local.yml` from the worktree, falling back to the main checkout.
    public static func load(worktreeRoot: String, projectRoot: String) throws -> XcdevConfig {
        guard let main = try? String(contentsOfFile: worktreeRoot + "/" + fileName, encoding: .utf8) else {
            throw XcdError(.configMissing, "no \(fileName) in \(worktreeRoot)", next: "run `xcd init` in the project root")
        }
        let local = [worktreeRoot, projectRoot].lazy
            .compactMap { try? String(contentsOfFile: $0 + "/" + localFileName, encoding: .utf8) }
            .first
        return try parse(main: main, local: local)
    }

    static func semanticIssues(_ config: XcdevConfig) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        if config.version != 1 {
            issues.append(ConfigIssue(path: "version", message: "unsupported version \(config.version) (this xcd supports 1)"))
        }
        let devices = config.allDevices
        if let name = config.defaultDevice, devices[name] == nil {
            issues.append(ConfigIssue(path: "defaultDevice", message: "'\(name)' is not a key under devices"))
        }
        for (name, spec) in devices.sorted(by: { $0.key < $1.key }) {
            if !spec.isMac && spec.type == nil {
                issues.append(ConfigIssue(path: "devices.\(name).type", message: "is required unless platform is macOS"))
            }
            if spec.isMac && spec.type != nil {
                issues.append(ConfigIssue(path: "devices.\(name)", message: "set either type or platform: macOS, not both"))
            }
            if let partner = spec.pairWith {
                if devices[partner] == nil || partner == name {
                    issues.append(ConfigIssue(path: "devices.\(name).pairWith", message: "'\(partner)' is not a key under devices"))
                } else if devices[partner]?.isMac == true {
                    issues.append(ConfigIssue(path: "devices.\(name).pairWith", message: "'\(partner)' is a macOS device and cannot be paired"))
                } else if devices[partner]?.pairWith != nil {
                    // Covers cycles (a↔b) and chains; provisioning pairs one level only.
                    issues.append(ConfigIssue(path: "devices.\(name).pairWith",
                                              message: "'\(partner)' also has pairWith; pairing chains are not supported"))
                }
            }
        }
        if let maxFollow = config.logs?.maxFollow, DurationText.parse(maxFollow) == nil {
            issues.append(ConfigIssue(path: "logs.maxFollow",
                                      message: "'\(maxFollow)' is not a duration like \"30s\", \"5m\", or \"1h\""))
        }
        issues += commandIssues(config.commands ?? [:])
        return issues
    }

    static func commandIssues(_ commands: [String: ProjectCommandSpec]) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        for (name, spec) in commands.sorted(by: { $0.key < $1.key }) {
            let path = "commands.\(name)"
            if name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) == nil {
                issues.append(ConfigIssue(path: path, message: "'\(name)' is not a valid command name (use letters, digits, '.', '_' or '-')"))
            } else if BuiltinCommands.reservedNames.contains(name) {
                issues.append(ConfigIssue(path: path, message: "'\(name)' is a built-in xcd command, so `xcd \(name)` would never run this; rename it"))
            }
            if spec.run.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(ConfigIssue(path: path + ".run", message: "must not be empty"))
            }
            for (index, need) in (spec.needs ?? []).enumerated() where !ProjectCommandSpec.needsValues.contains(need) {
                let hint = Suggest.closest(to: need, in: ProjectCommandSpec.needsValues, limit: 1).first.map { " (did you mean '\($0)'?)" } ?? ""
                issues.append(ConfigIssue(path: "\(path).needs[\(index)]",
                                          message: "'\(need)' is not one of: \(ProjectCommandSpec.needsValues.joined(separator: ", "))\(hint)"))
            }
            if let timeout = spec.timeout, DurationText.parse(timeout) == nil {
                issues.append(ConfigIssue(path: path + ".timeout", message: "'\(timeout)' is not a duration like \"30s\", \"10m\", or \"1h\""))
            }
        }
        return issues
    }

    private static func compose(_ yaml: String, file: String) throws -> Node {
        do {
            return try Yams.compose(yaml: yaml) ?? .mapping(Node.Mapping([]))
        } catch {
            throw XcdError(.configInvalid, "\(file) is not valid YAML", next: "fix the YAML syntax in \(file)",
                           details: ["\(error)"])
        }
    }

    private static func invalid(_ issues: [ConfigIssue], file: String = ConfigLoader.fileName) -> XcdError {
        let nextMsg = "fix \(file), then run `xcd config show`"
        return XcdError(.configInvalid, "\(file) is invalid (\(issues.count) problem\(issues.count == 1 ? "" : "s"))",
                 next: nextMsg, details: issues.map(\.line))
    }
}
