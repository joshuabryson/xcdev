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
        // What detection could not see comes first: it can explain a missing scheme or platform below.
        var notes = detected.notes
        var choices = [projectChoice(detected, containers: containers, folder: folder)]
        if let app = appSchemeChoice(detected, folder: folder) {
            choices.append(app)
        } else if detected.kind != .package {
            notes.append("no scheme builds an app; set schemes.app in .xcdev.yml to the scheme `xcd build` should use")
        }
        if let test = testSchemeChoice(detected) { choices.append(test) }

        let primary = primaryRole(detected)
        // Detection notes name the schemes whose platforms could not be read, which is then the real reason.
        if detected.kind != .package, detected.platforms.isEmpty, detected.notes.isEmpty {
            notes.append("no target reported its platforms, so this assumes an iOS app; change devices in .xcdev.yml if that's wrong")
        }
        if let primary, primary != .mac, let device = defaultDeviceChoice(primary, catalog: catalog, notes: &notes) {
            choices.append(device)
        }
        for role in secondaryRoles(detected, primary: primary) {
            choices.append(extraDeviceChoice(role, detected: detected, primary: primary, catalog: catalog, notes: &notes))
        }
        choices.append(xcodeChoice(xcodes))
        return InitPlan(detected: detected, xcodes: xcodes, selectedXcode: selected, primary: primary,
                        choices: choices, notes: notes)
    }

    static func projectChoice(_ detected: DetectedProject, containers: [String], folder: String) -> InitDecision {
        let projects = containers.isEmpty ? [detected.container] : containers
        let namedLikeFolder = URL(fileURLWithPath: projects[0]).deletingPathExtension().lastPathComponent == folder
        return InitDecision(
            key: "project", ask: "This folder has more than one project. Which one should xcd build?",
            options: projects, recommended: projects[0],
            reason: namedLikeFolder ? "it is named like the folder" : "it comes first alphabetically")
    }

    static func appSchemeChoice(_ detected: DetectedProject, folder: String) -> InitDecision? {
        guard let app = detected.appSchemes.first else { return nil }
        let base = URL(fileURLWithPath: detected.container).deletingPathExtension().lastPathComponent
        return InitDecision(
            key: "schemes.app", ask: "Which scheme should `xcd build` and `xcd run` use?",
            options: detected.appSchemes, recommended: app,
            reason: detected.kind == .package ? "it builds every product of the package"
                : app == base || app == folder ? "it builds an app and is named like the project"
                : "it builds an app and comes first alphabetically")
    }

    static func testSchemeChoice(_ detected: DetectedProject) -> InitDecision? {
        guard let test = detected.testSchemes.first else { return nil }
        return InitDecision(
            key: "schemes.test", ask: "Which scheme should `xcd test` run?", options: detected.testSchemes, recommended: test,
            reason: detected.kind == .package ? "it tests every target of the package"
                : test == detected.appSchemes.first ? "the app scheme's test action runs the tests" : "it is named for the app's tests")
    }

    /// Nil, with a note, when no device types are installed for `primary`.
    static func defaultDeviceChoice(_ primary: DeviceRole, catalog: SimCatalog, notes: inout [String]) -> InitDecision? {
        let found = DeviceSuggestions.choices(for: primary, catalog: catalog)
        if found.types.isEmpty {
            notes.append("no \(primary.noun) simulator types are installed; install them in Xcode > Settings > Components")
        }
        if found.runtime == nil { notes.append(runtimeNote(primary.platform)) }
        guard let first = found.types.first else { return nil }
        return InitDecision(
            key: "devices.default", ask: "Which \(primary.noun) should agents build and test on by default?",
            options: found.types, recommended: first,
            reason: found.runtime.map { "newest installed (\($0))" } ?? "newest model")
    }

    /// A device besides the default one. An app runs on each of its devices, and a clone is made only when a
    /// command uses it, so they are recommended; a package's platforms are often just deployment targets.
    static func extraDeviceChoice(_ role: DeviceRole, detected: DetectedProject, primary: DeviceRole?, catalog: SimCatalog,
                                  notes: inout [String]) -> InitDecision {
        let subject = detected.kind == .package ? "The package" : "Your app"
        if role == .mac {
            return InitDecision(
                key: "devices.mac", ask: "\(subject) also runs on macOS. Should agents be able to build and run it on this Mac with `--device mac`?",
                options: ["yes", "no"], recommended: "yes", reason: "Mac builds run on this Mac and need no simulator")
        }
        let found = DeviceSuggestions.choices(for: role, catalog: catalog)
        // An app's watch app can only run on a watch paired with its iPhone.
        let paired = role == .watch && primary == .iphone && detected.kind != .package
        let wanted = detected.kind != .package && found.runtime != nil && !found.types.isEmpty
        if found.runtime == nil { notes.append(runtimeNote(role.platform)) }
        return InitDecision(key: "devices." + role.rawValue, ask: extraDeviceAsk(role, subject: subject, paired: paired),
                            options: wanted ? found.types + ["none"] : ["none"] + found.types,
                            recommended: wanted ? found.types[0] : "none",
                            reason: extraDeviceReason(role, wanted: wanted, paired: paired, runtime: found.runtime))
    }

    static func extraDeviceAsk(_ role: DeviceRole, subject: String, paired: Bool) -> String {
        switch role {
        case .ipad: "\(subject) also runs on iPad. Should each worktree also get an iPad simulator, and which one?"
        case .watch where paired: "Your app has a watchOS app. Should each worktree also get a paired Apple Watch, and which one?"
        default: "\(subject) also supports \(role.platform.rawValue). Should each worktree also get \(role.withArticle) simulator, and which one?"
        }
    }

    static func extraDeviceReason(_ role: DeviceRole, wanted: Bool, paired: Bool, runtime: String?) -> String {
        if wanted, role == .watch {
            return paired ? "the watch app runs only on an Apple Watch paired with the iPhone" : "the watch app needs an Apple Watch simulator"
        }
        if wanted { return "your app runs on \(role.noun), and xcd clones it only for commands that use `--device \(role.rawValue)`" }
        if runtime == nil { return "no \(role.platform.rawValue) simulator runtime is installed yet" }
        return "add it when you test the package on \(role.noun)"
    }

    static func xcodeChoice(_ xcodes: [XcodeInstall]) -> InitDecision {
        var versions: [String] = []
        for install in xcodes where !versions.contains(install.version) { versions.append(install.version) }
        return InitDecision(
            key: "xcode", ask: "Pin a specific Xcode version, or use whatever is selected on this Mac?",
            options: ["system"] + versions, recommended: "system",
            reason: "it follows xcode-select, so updating Xcode needs no config change")
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
