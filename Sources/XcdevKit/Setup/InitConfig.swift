import Foundation

/// A .xcdev.yml generated from an init plan and the user's answers.
public struct GeneratedConfig: Sendable, Equatable {
    public let yaml: String
    /// One line per section, for the init report: "project: …", "schemes: …", "devices: …", "xcode: …".
    public let summary: [String]
}

extension InitPlan {
    /// Every key's chosen option: the answer when given, else the recommendation. Answers are validated:
    /// an unknown key, a key that doesn't apply to this project, or a value that isn't an option is `config_invalid`.
    public func resolve(_ answers: [String: String]) throws -> [String: String] {
        var chosen = Dictionary(uniqueKeysWithValues: choices.map { ($0.key, $0.recommended) })
        for (key, raw) in answers.sorted(by: { $0.key < $1.key }) {
            guard InitPlanner.keys.contains(key) else {
                let close = Suggest.closest(to: key, in: InitPlanner.keys, limit: 1)
                throw XcdError(.configInvalid, "'\(key)' is not an init key",
                               next: (close.first.map { "did you mean '\($0)'? " } ?? "") + "`xcd init --plan` lists this project's decisions")
            }
            guard let choice = choices.first(where: { $0.key == key }) else {
                throw XcdError(.configInvalid, "\(key) does not apply to this project",
                               next: "`xcd init --plan` lists this project's decisions: "
                                   + (decisions.isEmpty ? "none" : decisions.map(\.key).joined(separator: ", ")))
            }
            var value = raw.trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("devices."), key != "devices.default" {
                // yes/no/none mean the same thing for every optional device.
                let typed = choice.options.filter { $0 != "none" && $0 != "yes" && $0 != "no" }
                switch value.lowercased() {
                case "yes" where key != "devices.mac": value = typed.first ?? value
                case "no" where key != "devices.mac": value = "none"
                case "none" where key == "devices.mac": value = "no"
                default: break
                }
            }
            guard let option = choice.options.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
                throw XcdError(.configInvalid, "'\(raw)' is not an option for \(key)",
                               next: "use one of: " + choice.options.joined(separator: ", "))
            }
            chosen[key] = option
        }
        return chosen
    }

    /// The .xcdev.yml for `answers`. The YAML always passes `ConfigLoader.parse`.
    public func config(answers: [String: String]) throws -> GeneratedConfig {
        let chosen = try resolve(answers)
        var devices: [(name: String, spec: DeviceSpec)] = []
        if let primary {
            if primary == .mac {
                devices.append(("mac", DeviceSpec(platform: "macOS")))
            } else if let type = chosen["devices.default"] {
                devices.append((primary.rawValue, DeviceSpec(type: type, runtime: "latest")))
            }
        }
        for role in DeviceRole.allCases where role != primary {
            guard let value = chosen["devices." + role.rawValue], value != "none", value != "no" else { continue }
            if role == .mac {
                devices.append(("mac", DeviceSpec(platform: "macOS")))
            } else {
                let phone = role == .watch && devices.contains { $0.name == DeviceRole.iphone.rawValue }
                devices.append((role.rawValue, DeviceSpec(type: value, runtime: "latest", pairWith: phone ? "iphone" : nil)))
            }
        }
        var defaultDevice = devices.first?.name
        if primary == nil, !devices.isEmpty, !devices.contains(where: { $0.name == "mac" }) {
            // A package that builds on this Mac keeps the Mac as its default once it has devices.
            devices.insert(("mac", DeviceSpec(platform: "macOS")), at: 0)
            defaultDevice = "mac"
        }
        let xcode = chosen["xcode"].flatMap { $0 == "system" ? nil : $0 }
        let project = chosen["project"] ?? detected.container
        let app = chosen["schemes.app"]
        let test = chosen["schemes.test"]

        var lines = ["# xcdev project configuration, written by `xcd init`.",
                     "# Explain any key with `xcd config explain <key>`; walkthrough: `xcd guide setup`.",
                     "version: 1",
                     "project: " + YAMLText.quote(project)]
        if let xcode { lines.append("xcode: " + YAMLText.quote(xcode)) }
        if app != nil || test != nil {
            lines.append("schemes:")
            if let app { lines.append("  app: " + YAMLText.quote(app)) }
            if let test { lines.append("  test: " + YAMLText.quote(test)) }
        }
        if let defaultDevice { lines.append("defaultDevice: " + defaultDevice) }
        if !devices.isEmpty {
            lines.append("devices:")
            for (name, spec) in devices {
                var fields: [String] = []
                if let type = spec.type { fields.append("type: " + YAMLText.quote(type)) }
                if let runtime = spec.runtime { fields.append("runtime: " + runtime) }
                if let platform = spec.platform { fields.append("platform: " + platform) }
                if let pair = spec.pairWith { fields.append("pairWith: " + pair) }
                lines.append("  \(name): { " + fields.joined(separator: ", ") + " }")
            }
        }
        let yaml = lines.joined(separator: "\n") + "\n"
        do {
            _ = try ConfigLoader.parse(main: yaml)
        } catch {
            throw XcdError(.internalError, "xcd init generated an invalid .xcdev.yml", next: "this is a bug in xcd; please report it",
                           details: ["\(error)"] + lines)
        }

        let deviceSummary = devices.map { name, spec -> String in
            var text = "\(name)=" + (spec.type ?? "macOS")
            if name == defaultDevice { text += " (default)" }
            if let pair = spec.pairWith { text += " (paired with \(pair))" }
            return text
        }
        var summary = ["project: \(project)"]
        if app != nil || test != nil { summary.append("schemes: app=\(app ?? "-") test=\(test ?? "-")") }
        summary.append("devices: " + (devices.isEmpty ? "none (the package builds and tests on this Mac)" : deviceSummary.joined(separator: ", ")))
        summary.append("xcode: " + (xcode.map { "\($0) (pinned)" } ?? "system (the Xcode xcode-select points to)"))
        return GeneratedConfig(yaml: yaml, summary: summary)
    }
}

enum YAMLText {
    /// A double-quoted YAML scalar.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
