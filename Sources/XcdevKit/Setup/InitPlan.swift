import Foundation

/// One choice `xcd init` makes. With more than one option it is a decision for the user.
public struct InitDecision: Codable, Sendable, Equatable {
    /// A config key path, such as "devices.default" or "xcode".
    public let key: String
    /// A plain-language question an agent can relay as-is.
    public let ask: String
    /// Recommended first.
    public let options: [String]
    public let recommended: String
    public let reason: String
}

/// Everything `xcd init` detected and every choice it makes, before any answers are applied.
public struct InitPlan: Sendable, Equatable {
    public let detected: DetectedProject
    public let xcodes: [XcodeInstall]
    public let selectedXcode: XcodeInstall?
    /// The device every command uses by default; nil for a package that builds and tests on this Mac.
    public let primary: DeviceRole?
    /// Every choice, in `InitPlanner.keys` order, including ones with a single option.
    public let choices: [InitDecision]
    public let notes: [String]

    /// The choices the user has to make: those with more than one option.
    public var decisions: [InitDecision] { choices.filter { $0.options.count > 1 } }

    /// "27.0 (only install)", "27.0 selected; installed: 27.0, 26.5", or "none found".
    public var xcodeSummary: String {
        guard let selected = selectedXcode else {
            return xcodes.isEmpty ? "none found (install Xcode from https://developer.apple.com/xcode/)" : "none selected"
        }
        if xcodes.count <= 1 { return "\(selected.version) (only install)" }
        return "\(selected.version) selected; installed: " + xcodes.map(\.version).joined(separator: ", ")
    }
}

public enum InitPlanner {
    /// Every key `xcd init --set` understands, in the order decisions are asked.
    public static let keys = ["project", "schemes.app", "schemes.test", "devices.default"]
        + DeviceRole.allCases.map { "devices." + $0.rawValue } + ["xcode"]

    /// `containers` are the candidates from `ProjectDetector.containers(in:)`, best first; `folder` is the
    /// project root's name.
    public static func plan(detected: DetectedProject, containers: [String], folder: String, catalog: SimCatalog,
                            xcodes: [XcodeInstall], selected: XcodeInstall?) -> InitPlan {
        var choices: [InitDecision] = []
        // What detection could not see comes first: it can explain a missing scheme or platform below.
        var notes = detected.notes

        let projects = containers.isEmpty ? [detected.container] : containers
        let namedLikeFolder = URL(fileURLWithPath: projects[0]).deletingPathExtension().lastPathComponent == folder
        choices.append(InitDecision(
            key: "project", ask: "This folder has more than one project. Which one should xcd build?",
            options: projects, recommended: projects[0],
            reason: namedLikeFolder ? "it is named like the folder" : "it comes first alphabetically"))
        if let app = detected.appSchemes.first {
            let base = URL(fileURLWithPath: detected.container).deletingPathExtension().lastPathComponent
            choices.append(InitDecision(
                key: "schemes.app", ask: "Which scheme should `xcd build` and `xcd run` use?",
                options: detected.appSchemes, recommended: app,
                reason: detected.kind == .package ? "it builds every product of the package"
                    : app == base || app == folder ? "it builds an app and is named like the project"
                    : "it builds an app and comes first alphabetically"))
        } else if detected.kind != .package {
            notes.append("no scheme builds an app; set schemes.app in .xcdev.yml to the scheme `xcd build` should use")
        }
        if let test = detected.testSchemes.first {
            choices.append(InitDecision(
                key: "schemes.test", ask: "Which scheme should `xcd test` run?", options: detected.testSchemes, recommended: test,
                reason: detected.kind == .package ? "it tests every target of the package"
                    : test == detected.appSchemes.first ? "the app scheme's test action runs the tests" : "it is named for the app's tests"))
        }

        let primary = primaryRole(detected)
        // Detection notes name the schemes whose platforms could not be read, which is then the real reason.
        if detected.kind != .package, detected.platforms.isEmpty, detected.notes.isEmpty {
            notes.append("no target reported its platforms, so this assumes an iOS app; change devices in .xcdev.yml if that's wrong")
        }
        if let primary, primary != .mac {
            let found = DeviceSuggestions.choices(for: primary, catalog: catalog)
            if let first = found.types.first {
                choices.append(InitDecision(
                    key: "devices.default", ask: "Which \(primary.noun) should agents build and test on by default?",
                    options: found.types, recommended: first,
                    reason: found.runtime.map { "newest installed (\($0))" } ?? "newest model"))
            } else {
                notes.append("no \(primary.noun) simulator types are installed; install them in Xcode > Settings > Components")
            }
            if found.runtime == nil { notes.append(runtimeNote(primary.platform)) }
        }
        let subject = detected.kind == .package ? "The package" : "Your app"
        for role in secondaryRoles(detected, primary: primary) {
            if role == .mac {
                choices.append(InitDecision(
                    key: "devices.mac", ask: "\(subject) also runs on macOS. Should agents be able to build and run it on this Mac with `--device mac`?",
                    options: ["yes", "no"], recommended: "yes", reason: "Mac builds run on this Mac and need no simulator"))
                continue
            }
            let found = DeviceSuggestions.choices(for: role, catalog: catalog)
            // An app's watch app can only run on a watch; a package's watchOS support can be tested later.
            let paired = role == .watch && primary == .iphone && detected.kind != .package
            let ask: String
            switch role {
            case .ipad: ask = "\(subject) also runs on iPad. Should each worktree also get an iPad simulator, and which one?"
            case .watch where paired: ask = "Your app has a watchOS app. Should each worktree also get a paired Apple Watch, and which one?"
            default: ask = "\(subject) also supports \(role.platform.rawValue). Should each worktree also get \(role.withArticle) simulator, and which one?"
            }
            let wanted = role == .watch && detected.kind != .package && found.runtime != nil && !found.types.isEmpty
            let reason: String
            if wanted {
                reason = paired ? "the watch app runs only on an Apple Watch paired with the iPhone"
                                : "the watch app needs an Apple Watch simulator"
            } else if found.runtime == nil {
                reason = "no \(role.platform.rawValue) simulator runtime is installed yet"
                notes.append(runtimeNote(role.platform))
            } else {
                reason = "each extra device is another simulator in every worktree; add it when you work on \(role.platform.rawValue)"
            }
            choices.append(InitDecision(key: "devices." + role.rawValue, ask: ask,
                                        options: wanted ? found.types + ["none"] : ["none"] + found.types,
                                        recommended: wanted ? found.types[0] : "none", reason: reason))
        }

        var versions: [String] = []
        for install in xcodes where !versions.contains(install.version) { versions.append(install.version) }
        choices.append(InitDecision(
            key: "xcode", ask: "Pin a specific Xcode version, or use whatever is selected on this Mac?",
            options: ["system"] + versions, recommended: "system",
            reason: "it follows xcode-select, so updating Xcode needs no config change"))
        return InitPlan(detected: detected, xcodes: xcodes, selectedXcode: selected, primary: primary,
                        choices: choices, notes: notes)
    }

    /// The device commands use by default: nil for a package the Mac can build (it builds for the host).
    static func primaryRole(_ detected: DetectedProject) -> DeviceRole? {
        if detected.kind == .package, detected.platforms.isEmpty || detected.platforms.contains(.macOS) { return nil }
        switch detected.platforms.first {
        case .iOS?: return detected.deviceFamilies.isEmpty || detected.deviceFamilies.contains(1) ? .iphone : .ipad
        case .visionOS?: return .vision
        case .tvOS?: return .tv
        case .watchOS?: return .watch
        case .macOS?: return .mac
        case nil: return .iphone
        }
    }

    static func secondaryRoles(_ detected: DetectedProject, primary: DeviceRole?) -> [DeviceRole] {
        var roles: [DeviceRole] = []
        for platform in detected.platforms {
            switch platform {
            case .iOS:
                if primary == .iphone {
                    if detected.deviceFamilies.contains(2) { roles.append(.ipad) }
                } else if primary != .ipad {
                    roles.append(.iphone)
                }
            case .watchOS: roles.append(.watch)
            case .visionOS: roles.append(.vision)
            case .tvOS: roles.append(.tv)
            case .macOS: if primary != nil { roles.append(.mac) }
            }
        }
        return DeviceRole.allCases.filter { roles.contains($0) && $0 != primary }
    }

    static func runtimeNote(_ platform: AppPlatform) -> String {
        "no \(platform.rawValue) simulator runtime is installed; run `xcodebuild -downloadPlatform \(platform.rawValue)` before using that device"
    }
}

/// `xcd init --plan`: what was detected and the decisions to ask the user. Writes nothing.
public struct InitPlanReport: Reportable {
    public let root: String
    public let detected: DetectedProject
    public let xcode: String
    public let decisions: [InitDecision]
    public let notes: [String]
    public let configExists: Bool

    public init(plan: InitPlan, root: String, configExists: Bool) {
        self.root = root
        detected = plan.detected
        xcode = plan.xcodeSummary
        decisions = plan.decisions
        notes = plan.notes + (configExists ? ["a .xcdev.yml already exists; applying answers needs `--force`, which replaces it"] : [])
        self.configExists = configExists
    }

    public var text: String {
        let platforms = detected.platforms.isEmpty ? "any (builds for this Mac)" : detected.platforms.map(\.rawValue).joined(separator: ", ")
        var lines = ["detected: \(detected.container), schemes=[\(detected.schemes.joined(separator: ", "))], platforms=[\(platforms)]",
                     "xcode: \(xcode)"]
        for decision in decisions {
            lines += ["", "decision \(decision.key)", "  ask: \"\(decision.ask)\""]
            let options = decision.options.map { $0 == decision.recommended ? "\($0) (recommended: \(decision.reason))" : $0 }
            lines.append("  options: " + options.joined(separator: ", "))
        }
        if decisions.isEmpty { lines += ["", "no decisions: every choice has a single option"] }
        if !notes.isEmpty { lines.append("") }
        lines += notes.map { "note: " + $0 }
        lines.append("next: ask the user each decision, then run `xcd init --set <key>=<value> …`, or `xcd init --defaults`")
        return lines.joined(separator: "\n")
    }
}
