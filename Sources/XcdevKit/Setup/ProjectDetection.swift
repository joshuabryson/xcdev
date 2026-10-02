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
            var platforms = Set((s["SUPPORTED_PLATFORMS"] ?? "").split(separator: " ").compactMap { AppPlatform(sdk: String($0)) }).sorted()
            if s["IS_MACCATALYST"] == "YES" || s["SUPPORTS_MACCATALYST"] == "YES" { platforms = Catalyst.asIOS(platforms) }
            let families = (s["TARGETED_DEVICE_FAMILY"] ?? "").split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != Catalyst.deviceFamily }
            return AppTarget(name: entry.target, isApp: isApp, platforms: platforms, deviceFamilies: families)
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

/// Finds the project container, its schemes, and its platforms, cheapest way first:
/// 1. the project files (`ProjectFileReader`), when they say enough: no xcodebuild at all;
/// 2. xcodebuild, with an APFS clone of Swift packages already resolved for this project (by this worktree's builds,
///    or by Xcode in its DerivedData) and package resolution turned off, so nothing is fetched;
/// 3. xcodebuild resolving the packages afresh into the scratch folder (a minute or more for a big package graph).
/// Nothing is written inside the project or Xcode's DerivedData: xcodebuild and SwiftPM keep their state in `scratch`.
public struct ProjectDetector: Sendable {
    public let runner: any ProcessRunning
    public let developerDir: String?
    /// For xcodebuild's DerivedData, package checkouts, and SwiftPM's build folders. The caller deletes it.
    public let scratch: String
    /// Where Xcode keeps DerivedData, searched for packages it already resolved for the project.
    public let xcodeDerivedData: String
    /// Reports the steps that can take a while: reading packages' manifests, listing schemes, reading build settings.
    public let progress: Activity
    /// Schemes whose build settings are read; the rest are ignored (workspaces with Pods have dozens).
    public static let maxSchemes = 12
    /// How long `xcodebuild -list` may take. Without resolved packages it resolves them first, which on a cold cache
    /// means cloning them all (about 45s for Firebase on a fast network), so it gets far more than the usual 2 minutes.
    public static let listTimeout: Duration = .seconds(600)
    /// Xcode's default DerivedData folder.
    public static let defaultXcodeDerivedData = NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
    /// Keep xcodebuild from fetching: use only the packages, at the versions, already resolved.
    static let noResolution = ["-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile"]
    static let skippedFolders: Set<String> = ["build", "DerivedData", "Pods", "Carthage", "node_modules"]

    /// Clones a folder tree: 0, or why not (an errno). Tests replace it.
    let cloneTree: @Sendable (_ source: String, _ destination: String) -> Int32

    public init(runner: any ProcessRunning, developerDir: String?, scratch: String,
                xcodeDerivedData: String = ProjectDetector.defaultXcodeDerivedData, progress: Activity = .silent,
                cloneTree: @escaping @Sendable (String, String) -> Int32 = ProjectDetector.cloneTree) {
        self.runner = runner
        self.developerDir = developerDir
        self.scratch = scratch
        self.xcodeDerivedData = xcodeDerivedData
        self.progress = progress
        self.cloneTree = cloneTree
    }

    /// `clonefile(2)` on the whole tree at once: 0, or the errno.
    public static func cloneTree(_ source: String, _ destination: String) -> Int32 {
        clonefile(source, destination, 0) == 0 ? 0 : errno
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

    public func detect(root: String, container: String, projectRoot: String? = nil) async throws -> DetectedProject {
        let resolved = try ProjectContainer.resolve(config: XcdevConfig(version: 1, project: container), worktreeRoot: root)
        if case .package(let directory) = resolved {
            return try await detectPackage(container: container, directory: directory)
        }
        let names = [URL(fileURLWithPath: container).deletingPathExtension().lastPathComponent, URL(fileURLWithPath: root).lastPathComponent]
        switch try await ProjectFileReader(runner: runner, developerDir: developerDir, scratch: scratch, progress: progress).read(resolved) {
        case .confident(let schemes):
            let targets = Dictionary(uniqueKeysWithValues: schemes.map { ($0.name, $0.targets) })
            return Self.assemble(container: container, schemes: schemes.map(\.name), read: Self.readOrder(schemes.map(\.name), names: names),
                                 targetsByScheme: targets, names: names, notes: [])
        case .unsure(let reason):
            return try await detectWithXcodebuild(resolved, root: root, container: container, names: names,
                                                  notes: [reason + "; asked xcodebuild"], projectRoot: projectRoot)
        }
    }

    /// Tiers 2 and 3: `xcodebuild -list`, then `-showBuildSettings` for each scheme up to `maxSchemes`.
    /// `projectRoot` is the main checkout, whose packages a new worktree can use.
    func detectWithXcodebuild(_ resolved: ProjectContainer, root: String, container: String, names: [String],
                              notes: [String], projectRoot: String? = nil) async throws -> DetectedProject {
        var notes = notes
        let created = Self.foldersXcodebuildMayCreate(resolved).filter { !FileManager.default.fileExists(atPath: $0) }
        defer { Self.removeEmpty(created) }
        let scratchPaths = WorktreePaths(root: scratch)
        let packages = scratchPaths.sourcePackages
        var list: ProcessOutput?
        var extra: [String] = []
        if let resolvedPackages = Self.resolvedPackages(for: resolved, container: container, worktree: root, projectRoot: projectRoot,
                                                        xcodeDerivedData: xcodeDerivedData),
           try await clone(resolvedPackages, to: packages, container: container, notes: &notes) {
            do {
                list = try await listSchemes(resolved, container: container, packages: packages, paths: scratchPaths,
                                             extra: Self.noResolution, alreadyResolved: true)
                extra = Self.noResolution
            } catch let error as XcdError where error.code != .timeout {
                // Most likely Package.resolved changed since those packages were resolved.
                notes.append("xcodebuild could not use the Swift packages already resolved in \(resolvedPackages) (\(error.message)), "
                             + "so it resolved them again")
                try? FileManager.default.removeItem(atPath: packages)
            }
        }
        let listed: ProcessOutput
        if let list {
            listed = list
        } else {
            listed = try await listSchemes(resolved, container: container, packages: packages, paths: scratchPaths, extra: [],
                                           alreadyResolved: false)
        }
        let schemes = Schemes.parseList(listed.stdout)
        let packageArguments = extra
        let readOrder = Self.readOrder(schemes, names: names)
        let ordered = Array(readOrder.prefix(Self.maxSchemes))
        let count = "\(ordered.count) scheme\(ordered.count == 1 ? "" : "s")"
        let results = try await progress.step("reading the build settings of \(count)…", done: "read the build settings of \(count)") {
            await withTaskGroup(of: (String, SchemeSettings).self) { group in
                for scheme in ordered {
                    group.addTask {
                        let request = XcodebuildRequest(actions: [], container: resolved, scheme: scheme, paths: scratchPaths)
                        var invocation = request.buildSettingsInvocation(developerDir: developerDir)
                        invocation.arguments += packageArguments
                        return (scheme, await readTargets(invocation))
                    }
                }
                var result: [String: SchemeSettings] = [:]
                for await (scheme, targets) in group { result[scheme] = targets }
                return result
            }
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
        return Self.assemble(container: container, schemes: schemes, read: ordered, targetsByScheme: targetsByScheme,
                             names: names, notes: notes)
    }

    /// The detected project from each read scheme's targets. `read` are the schemes whose targets are known, in
    /// `readOrder`; `names` are the container's and the folder's names.
    static func assemble(container: String, schemes: [String], read: [String], targetsByScheme: [String: [AppTarget]],
                         names: [String], notes: [String]) -> DetectedProject {
        // A scheme's own app is the first app it lists (a watch app's scheme lists the watch app, then its companion).
        // Watch apps' schemes are offered only when no other scheme builds an app: they can't run on a phone.
        func watchScheme(_ scheme: String) -> Bool {
            (targetsByScheme[scheme] ?? []).first(where: \.isApp)?.platforms == [.watchOS]
        }
        let withApps = read.filter { (targetsByScheme[$0] ?? []).contains(where: \.isApp) }
        let phoneOrMac = withApps.filter { !watchScheme($0) }
        // Named like the container or the folder first, as in `readOrder`, then alphabetically.
        func rank(_ scheme: String) -> Int { names.contains(scheme) ? 0 : 1 }
        let appSchemes = (phoneOrMac.isEmpty ? withApps : phoneOrMac).sorted { (rank($0), $0) < (rank($1), $1) }
        let all = read.flatMap { targetsByScheme[$0] ?? [] }
        let source = all.contains(where: \.isApp) ? all.filter(\.isApp) : all
        let platforms = Set(source.flatMap(\.platforms)).sorted()
        let families = Set(source.filter { $0.platforms.contains(.iOS) }.flatMap(\.deviceFamilies)).sorted()
        let kind: DetectedProject.Kind = container.hasSuffix(".xcworkspace") ? .workspace : .project
        return DetectedProject(container: container, kind: kind, schemes: schemes, appSchemes: appSchemes,
                               testSchemes: testSchemes(schemes, app: appSchemes.first),
                               platforms: platforms, deviceFamilies: families, notes: notes)
    }

    /// Swift packages already resolved for this container: this worktree's own (from `xcd build`), else the most
    /// recently resolved of Xcode's DerivedData folders whose info.plist names the container, else (for a new
    /// worktree) one that names the same container in the main checkout `projectRoot`. `container` is relative to
    /// the worktree.
    static func resolvedPackages(for resolved: ProjectContainer, container: String, worktree: String, projectRoot: String?,
                                 xcodeDerivedData: String) -> String? {
        // workspace-state.json records the packages (identity, location, version), not the project they were
        // resolved for, so this folder can't be checked against the container. It is this worktree's own, from
        // `xcd build` of its configured project, almost always this container. If it isn't, and its packages don't
        // satisfy this container's Package.resolved, xcodebuild -list fails with resolution off and detection
        // resolves afresh (the fallback in `detectWithXcodebuild`); extra packages it doesn't need are harmless.
        let own = WorktreePaths(root: worktree).sourcePackages
        if FileManager.default.fileExists(atPath: own + "/workspace-state.json") { return own }
        let path: String
        switch resolved {
        case .workspace(let p), .project(let p): path = p
        case .package: return nil
        }
        if let found = xcodeResolved(path, in: xcodeDerivedData) { return found }
        guard let projectRoot else { return nil }
        let main = URL(fileURLWithPath: projectRoot).appendingPathComponent(container).standardizedFileURL.path
        return main == path ? nil : xcodeResolved(main, in: xcodeDerivedData)
    }

    /// The most recently resolved SourcePackages in Xcode's DerivedData for the workspace or project at `path`.
    static func xcodeResolved(_ path: String, in xcodeDerivedData: String) -> String? {
        let fm = FileManager.default
        func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        let wanted = canonical(path)
        var best: (folder: String, modified: Date)?
        for entry in (try? fm.contentsOfDirectory(atPath: xcodeDerivedData)) ?? [] {
            let folder = xcodeDerivedData + "/" + entry
            guard let data = fm.contents(atPath: folder + "/info.plist"),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let workspace = info["WorkspacePath"] as? String, canonical(workspace) == wanted,
                  let modified = (try? fm.attributesOfItem(atPath: folder + "/SourcePackages/workspace-state.json"))?[.modificationDate] as? Date
            else { continue }
            if best.map({ modified > $0.modified }) ?? true { best = (folder + "/SourcePackages", modified) }
        }
        return best?.folder
    }

    /// Clones `source` to `destination` with one `clonefile(2)` of the whole tree: instant, and no extra space.
    /// xcodebuild rewrites checkouts' git indexes and workspace-state.json even with package resolution off, so it
    /// never gets the original. False, with a note, when the clone fails (EXDEV across volumes, ENOTSUP off APFS).
    func clone(_ source: String, to destination: String, container: String, notes: inout [String]) async throws -> Bool {
        try? FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let code = try await progress.step("copying the Swift packages already resolved for \(container) from \(source)…",
                                           done: "copied the resolved Swift packages") { [cloneTree] in cloneTree(source, destination) }
        guard code == 0 else {
            try? FileManager.default.removeItem(atPath: destination)
            let reason = String(cString: strerror(code))
            notes.append("could not clone the Swift packages already resolved in \(source) (\(reason)), so xcodebuild resolved them again")
            return false
        }
        return true
    }

    /// The folders `xcodebuild -list` creates in a project or workspace if they're missing, outermost first.
    static func foldersXcodebuildMayCreate(_ resolved: ProjectContainer) -> [String] {
        let outer: [String]
        switch resolved {
        case .project(let path): outer = [path + "/project.xcworkspace", path + "/project.xcworkspace/xcshareddata"]
        case .workspace(let path): outer = [path + "/xcshareddata"]
        case .package: return []
        }
        let shared = outer.last!
        return outer + [shared + "/swiftpm", shared + "/swiftpm/configuration"]
    }

    /// Removes each folder that is empty, innermost first; a folder with anything in it stays.
    static func removeEmpty(_ folders: [String]) {
        for folder in folders.reversed() { rmdir(folder) }
    }

    /// `xcodebuild -list`. Without `alreadyResolved` it first resolves the Swift packages into `packages`, and a
    /// timeout says so, since that is what takes the time.
    func listSchemes(_ resolved: ProjectContainer, container: String, packages: String, paths: WorktreePaths, extra: [String],
                     alreadyResolved: Bool) async throws -> ProcessOutput {
        var invocation = Schemes.listInvocation(resolved, paths: paths, developerDir: developerDir, timeout: Self.listTimeout)
        // -list rejects -derivedDataPath, and would otherwise write logs into Xcode's DerivedData.
        invocation.arguments += extra + ["-IDECustomDerivedDataLocation=" + scratch + "/XcodeDerivedData"]
        let message = alreadyResolved
            ? "listing the schemes of \(container) with its resolved Swift packages…"
            : "listing the schemes of \(container): no resolved Swift packages found for this project; resolving them (can take a minute)…"
        do {
            return try await progress.step(message, done: "listed the schemes of \(container)") {
                try await runner.runChecked(invocation)
            }
        } catch var error as XcdError {
            if error.code == .timeout, !alreadyResolved {
                error.next = "it was resolving the Swift packages of \(container); check the network and the package URLs, "
                    + "then run `xcd init --plan` again"
            } else if error.code != .timeout {
                error.next = "run `xcodebuild -list` in the project folder to see why"
            }
            throw error
        }
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

    /// A package is read from its manifest alone: `dump-package` fetches none of its dependencies (xcodebuild would).
    func detectPackage(container: String, directory: String) async throws -> DetectedProject {
        let dump = ProjectFileReader.dumpPackage(in: directory, scratchPath: scratch + "/swiftpm", developerDir: developerDir)
        let out = try await progress.step("reading Package.swift with `swift package dump-package`…", done: "read Package.swift") {
            try await runner.runChecked(dump, next: "run `swift package dump-package` in the package folder to check Package.swift")
        }
        let manifest = try PackageManifest.parse(out.stdout)
        let schemes = try PackageLayout.parse(out.stdout).schemes(as: .root)
            .sorted { ($0.lowercased(), $0) < ($1.lowercased(), $1) }
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
