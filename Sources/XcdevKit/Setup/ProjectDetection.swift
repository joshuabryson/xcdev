import Foundation

/// A platform an app (or package) supports. The case order is the preference for the default device.
public enum AppPlatform: String, Codable, Sendable, CaseIterable, Comparable {
    case iOS, visionOS, tvOS, watchOS, macOS

    public static func < (lhs: AppPlatform, rhs: AppPlatform) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// From an SDK name in SUPPORTED_PLATFORMS ("iphonesimulator", "watchos", "macosx", …).
    public init?(sdk: String) {
        switch sdk {
        case "iphoneos", "iphonesimulator": self = .iOS
        case "xros", "xrsimulator": self = .visionOS
        case "appletvos", "appletvsimulator": self = .tvOS
        case "watchos", "watchsimulator": self = .watchOS
        case "macosx": self = .macOS
        default: return nil
        }
    }

    /// From `platformName` in `swift package dump-package` ("ios", "macos", …).
    public init?(packagePlatform: String) {
        switch packagePlatform {
        case "ios": self = .iOS
        case "visionos": self = .visionOS
        case "tvos": self = .tvOS
        case "watchos": self = .watchOS
        case "macos": self = .macOS
        default: return nil
        }
    }
}

/// One target from `xcodebuild -showBuildSettings -json`.
public struct AppTarget: Codable, Sendable, Equatable {
    public let name: String
    public let isApp: Bool
    public let platforms: [AppPlatform]
    /// TARGETED_DEVICE_FAMILY: 1 iPhone, 2 iPad, 3 Apple TV, 4 Apple Watch, 7 Apple Vision.
    public let deviceFamilies: [Int]

    /// Targets in output order, each once (a test host can be listed twice). Empty when unreadable.
    public static func parse(_ data: Data) -> [AppTarget] {
        struct Entry: Decodable { let target: String; let buildSettings: [String: String] }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard seen.insert(entry.target).inserted else { return nil }
            let s = entry.buildSettings
            let isApp = (s["PRODUCT_TYPE"] ?? "").hasPrefix("com.apple.product-type.application")
            let platforms = Set((s["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").compactMap { AppPlatform(sdk: String($0)) })
            let families = (s["TARGETED_DEVICE_FAMILY"] ?? "").split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return AppTarget(name: entry.target, isApp: isApp, platforms: platforms.sorted(), deviceFamilies: families)
        }
    }
}

/// The name and declared platforms from `swift package dump-package`.
public struct PackageManifest: Sendable, Equatable {
    public let name: String
    /// Empty when the package declares no platforms (it then builds for every platform, including the Mac).
    public let platforms: [AppPlatform]

    public static func parse(_ data: Data) throws -> PackageManifest {
        struct Platform: Decodable { let platformName: String }
        struct Raw: Decodable { let name: String; let platforms: [Platform]? }
        do {
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            let platforms = Set((raw.platforms ?? []).compactMap { AppPlatform(packagePlatform: $0.platformName) })
            return PackageManifest(name: raw.name, platforms: platforms.sorted())
        } catch {
            throw XcdError(.subprocessFailed, "could not read `swift package dump-package` output",
                           next: "run `swift package dump-package` in the package folder to check Package.swift",
                           details: ["\(error)"])
        }
    }
}

/// What `xcd init` found in a project.
public struct DetectedProject: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case workspace, project, package }

    /// Relative to the project root, as written to `project:`.
    public var container: String
    public var kind: Kind
    public var schemes: [String]
    /// Schemes that build an app (for a package: its schemes), best first.
    public var appSchemes: [String]
    /// Candidate test schemes, best first.
    public var testSchemes: [String]
    /// Sorted by preference for the default device. Empty for a package that declares no platforms.
    public var platforms: [AppPlatform]
    /// TARGETED_DEVICE_FAMILY values of the iOS targets (1 iPhone, 2 iPad).
    public var deviceFamilies: [Int]
    /// What detection could not see, each naming the scheme and why (a failed `-showBuildSettings`, schemes past the cap).
    public var notes: [String] = []
}

/// Finds the project container, its schemes, and its platforms. Nothing is written inside the project:
/// xcodebuild and SwiftPM keep their state in `scratch`.
public struct ProjectDetector: Sendable {
    public let runner: any ProcessRunning
    public let developerDir: String?
    /// For xcodebuild's DerivedData and package checkouts, and SwiftPM's build folder. The caller deletes it.
    public let scratch: String
    /// Schemes whose build settings are read; the rest are ignored (workspaces with Pods have dozens).
    public static let maxSchemes = 12
    static let skippedFolders: Set<String> = ["build", "DerivedData", "Pods", "Carthage", "node_modules"]

    public init(runner: any ProcessRunning, developerDir: String?, scratch: String) {
        self.runner = runner
        self.developerDir = developerDir
        self.scratch = scratch
    }

    /// The best containers in `root` or its direct subfolders, relative to `root`: the shallowest ones, preferring
    /// .xcworkspace over .xcodeproj over Package.swift. More than one means the user must choose. Best first.
    public static func containers(in root: String) -> [String] {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: root).lastPathComponent
        var found: [(path: String, depth: Int, rank: Int)] = []
        func scan(_ directory: String, relative: String, depth: Int) {
            for entry in ((try? fm.contentsOfDirectory(atPath: directory)) ?? []) where !entry.hasPrefix(".") {
                let path = relative.isEmpty ? entry : relative + "/" + entry
                if entry.hasSuffix(".xcworkspace") {
                    found.append((path, depth, 0))
                } else if entry.hasSuffix(".xcodeproj") {
                    found.append((path, depth, 1))
                } else if entry == "Package.swift" {
                    found.append((path, depth, 2))
                } else if depth == 0, !skippedFolders.contains(entry) {
                    var isDirectory: ObjCBool = false
                    if fm.fileExists(atPath: directory + "/" + entry, isDirectory: &isDirectory), isDirectory.boolValue {
                        scan(directory + "/" + entry, relative: path, depth: 1)
                    }
                }
            }
        }
        scan(root, relative: "", depth: 0)
        guard let best = found.min(by: { ($0.depth, $0.rank) < ($1.depth, $1.rank) }) else { return [] }
        func matchesFolder(_ path: String) -> Bool {
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent == folder
        }
        return found.filter { $0.depth == best.depth && $0.rank == best.rank }.map(\.path)
            .sorted { (matchesFolder($0) ? 0 : 1, $0) < (matchesFolder($1) ? 0 : 1, $1) }
    }

    public func detect(root: String, container: String) async throws -> DetectedProject {
        let resolved = try ProjectContainer.resolve(config: XcdevConfig(version: 1, project: container), worktreeRoot: root)
        let scratchPaths = WorktreePaths(root: scratch)
        let list = try await runner.runChecked(Schemes.listInvocation(resolved, paths: scratchPaths, developerDir: developerDir),
                                               next: "run `xcodebuild -list` in the project folder to see why")
        let schemes = Schemes.parseList(list.stdout)
        if case .package(let directory) = resolved {
            return try await detectPackage(container: container, directory: directory, schemes: schemes)
        }
        let base = URL(fileURLWithPath: container).deletingPathExtension().lastPathComponent
        let folder = URL(fileURLWithPath: root).lastPathComponent
        let names = [base, folder]
        let readOrder = Self.readOrder(schemes, names: names)
        let ordered = Array(readOrder.prefix(Self.maxSchemes))
        var notes: [String] = []
        let results = await withTaskGroup(of: (String, SchemeSettings).self) { group in
            for scheme in ordered {
                group.addTask {
                    let request = XcodebuildRequest(actions: [], container: resolved, scheme: scheme, paths: scratchPaths)
                    return (scheme, await readTargets(request.buildSettingsInvocation(developerDir: developerDir)))
                }
            }
            var result: [String: SchemeSettings] = [:]
            for await (scheme, targets) in group { result[scheme] = targets }
            return result
        }
        var targetsByScheme: [String: [AppTarget]] = [:]
        for scheme in ordered {
            switch results[scheme] {
            case .read(let targets)?: targetsByScheme[scheme] = targets
            case .unreadable(let reason)?:
                notes.append("could not read the build settings of scheme \"\(scheme)\" (\(reason)), so its platforms are not included")
            case nil: break
            }
        }
        if readOrder.count > ordered.count {
            let skipped = readOrder.dropFirst(ordered.count)
            notes.append("read the build settings of \(ordered.count) of \(schemes.count) schemes; not read: "
                         + skipped.joined(separator: ", ") + " (set schemes.app in .xcdev.yml if the app is among them)")
        }
        // A scheme's own app is the first app it lists (a watch app's scheme lists the watch app, then its companion).
        // Watch apps' schemes are offered only when no other scheme builds an app: they can't run on a phone.
        func watchScheme(_ scheme: String) -> Bool {
            (targetsByScheme[scheme] ?? []).first(where: \.isApp)?.platforms == [.watchOS]
        }
        let withApps = ordered.filter { (targetsByScheme[$0] ?? []).contains(where: \.isApp) }
        let phoneOrMac = withApps.filter { !watchScheme($0) }
        // Named like the container or the folder first, as in `readOrder`, then alphabetically.
        func rank(_ scheme: String) -> Int { names.contains(scheme) ? 0 : 1 }
        let appSchemes = (phoneOrMac.isEmpty ? withApps : phoneOrMac).sorted { (rank($0), $0) < (rank($1), $1) }
        let all = targetsByScheme.values.flatMap { $0 }
        let source = all.contains(where: \.isApp) ? all.filter(\.isApp) : all
        let platforms = Set(source.flatMap(\.platforms)).sorted()
        let families = Set(source.filter { $0.platforms.contains(.iOS) }.flatMap(\.deviceFamilies)).sorted()
        let kind: DetectedProject.Kind = container.hasSuffix(".xcworkspace") ? .workspace : .project
        return DetectedProject(container: container, kind: kind, schemes: schemes, appSchemes: appSchemes,
                               testSchemes: Self.testSchemes(schemes, app: appSchemes.first),
                               platforms: platforms, deviceFamilies: families, notes: notes)
    }

    /// The order in which schemes' build settings are read, so the app's scheme is inside the cap: schemes named like
    /// the container or the folder, then the rest in xcodebuild's order, then the ones that can't be the app
    /// (tests, CocoaPods' umbrella "Pods-…" schemes).
    static func readOrder(_ schemes: [String], names: [String]) -> [String] {
        func rank(_ scheme: String) -> Int {
            if names.contains(scheme) { return 0 }
            return scheme.hasSuffix("Tests") || scheme.hasPrefix("Pods-") ? 2 : 1
        }
        return schemes.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    /// One scheme's targets, or why its build settings could not be read.
    enum SchemeSettings: Sendable {
        case read([AppTarget])
        case unreadable(String)
    }

    func readTargets(_ invocation: Invocation) async -> SchemeSettings {
        let command = "`" + invocation.argv.dropFirst().prefix(2).joined(separator: " ") + "`"  // `xcodebuild -showBuildSettings`
        do {
            let output = try await runner.run(invocation)
            guard output.succeeded else {
                let lines = output.stderrString.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                let detail = lines.last { $0.contains("error:") } ?? lines.last
                return .unreadable("\(command) exit \(output.exitCode)" + (detail.map { ": " + $0 } ?? ""))
            }
            return .read(AppTarget.parse(output.stdout))
        } catch let error as XcdError {
            return .unreadable(error.message)
        } catch {
            return .unreadable("\(command) could not run: \(error)")
        }
    }

    func detectPackage(container: String, directory: String, schemes: [String]) async throws -> DetectedProject {
        var dump = Invocation.xcrun(["swift", "package", "--scratch-path", scratch + "/swiftpm", "dump-package"],
                                    developerDir: developerDir, timeout: .seconds(120))
        dump.workingDirectory = directory
        let out = try await runner.runChecked(dump, next: "run `swift package dump-package` in the package folder to check Package.swift")
        let manifest = try PackageManifest.parse(out.stdout)
        // A package with several products also gets a "<name>-Package" scheme that builds and tests everything.
        let all = manifest.name + "-Package"
        let ranked = schemes.sorted { ($0 == all ? 0 : 1, $0) < ($1 == all ? 0 : 1, $1) }
        return DetectedProject(container: container, kind: .package, schemes: schemes, appSchemes: ranked,
                               testSchemes: ranked, platforms: manifest.platforms, deviceFamilies: [])
    }

    /// Schemes named like tests ("<app>Tests" first, UI tests last), then the app scheme, whose test action
    /// usually runs the unit tests.
    static func testSchemes(_ schemes: [String], app: String?) -> [String] {
        func rank(_ scheme: String) -> Int {
            if let app, scheme == app + "Tests" { return 0 }
            return scheme.hasSuffix("UITests") ? 2 : 1
        }
        var result = schemes.filter { $0.hasSuffix("Tests") }.sorted { (rank($0), $0) < (rank($1), $1) }
        if let app, !result.contains(app) { result.append(app) }
        return result
    }
}
