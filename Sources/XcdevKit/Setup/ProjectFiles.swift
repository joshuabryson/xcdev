import Foundation

/// The first and cheapest way `xcd init` learns about a project: reading the files Xcode itself reads (project.pbxproj,
/// .xcscheme files, the workspace's contents, and local packages' manifests) instead of asking xcodebuild, which first
/// resolves every Swift package (over a gigabyte for a Firebase app). Only `swift package dump-package` runs, once per
/// local package; it evaluates the manifest and fetches nothing.
///
/// The result is used only when it is certain of what `init` decides with: at least one scheme builds an app, and the
/// platform of every app target is known. Anything else is `.unsure`, saying why, and detection asks xcodebuild.
public struct ProjectFileReader: Sendable {
    public let runner: any ProcessRunning
    public let developerDir: String?
    /// For SwiftPM's build folders (`<scratch>/swiftpm-<n>`). The caller deletes it.
    public let scratch: String
    /// Shows reading the local packages' manifests, the one step that runs anything.
    public let progress: Activity

    public init(runner: any ProcessRunning, developerDir: String?, scratch: String, progress: Activity = .silent) {
        self.runner = runner
        self.developerDir = developerDir
        self.scratch = scratch
        self.progress = progress
    }

    /// A scheme and the targets its build action builds, in its order (none for a package's scheme).
    public struct Scheme: Sendable, Equatable {
        public let name: String
        public let targets: [AppTarget]
    }

    public enum Outcome: Sendable, Equatable {
        /// Every scheme, sorted as `xcodebuild -list` sorts them.
        case confident([Scheme])
        /// Why the files aren't enough, for a note.
        case unsure(String)
    }

    public func read(_ container: ProjectContainer) async -> Outcome {
        do {
            return try await readFiles(container)
        } catch let unreadable as Unreadable {
            return .unsure(unreadable.reason)
        } catch {
            return .unsure("could not read the project files (\(error))")
        }
    }

    struct Unreadable: Error { let reason: String }

    func readFiles(_ container: ProjectContainer) async throws -> Outcome {
        let base: String
        let projectPaths: [String]
        var packageFolders: [String] = []
        var schemeFolders: [(folder: String, base: String)] = []
        let settingsFile: String
        switch container {
        case .package:
            throw Unreadable(reason: "a Swift package has no project files")
        case .project(let path):
            base = (path as NSString).deletingLastPathComponent
            projectPaths = [path]
            settingsFile = path + "/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings"
        case .workspace(let path):
            base = (path as NSString).deletingLastPathComponent
            let members = try WorkspaceContents.read(path, relativeTo: base)
            projectPaths = members.projects
            packageFolders = members.packageFolders
            schemeFolders = Self.schemeFolders(in: path).map { ($0, base) }
            settingsFile = path + "/xcshareddata/WorkspaceSettings.xcsettings"
        }
        func relative(_ path: String) -> String {
            path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        }
        var projects: [XcodeProjectFile] = []
        for path in projectPaths {
            guard let project = XcodeProjectFile.read(path) else {
                throw Unreadable(reason: "could not read \(relative(path))/project.pbxproj")
            }
            projects.append(project)
            schemeFolders += Self.schemeFolders(in: path).map { ($0, (path as NSString).deletingLastPathComponent) }
        }

        var schemes: [Scheme] = []
        var built: [String: Set<String>] = [:]      // project path → blueprint IDs and names some scheme builds
        var apps: [XcodeProjectFile.Target] = []
        func taken(_ name: String) -> Bool { schemes.contains { $0.name == name } }
        for (folder, schemeBase) in schemeFolders {
            for file in Self.files(in: folder, ending: ".xcscheme") {
                let name = String(file.dropLast(".xcscheme".count))
                guard !taken(name) else { continue }
                guard let references = SchemeFile.buildables(folder + "/" + file) else {
                    throw Unreadable(reason: "could not read \(relative(folder + "/" + file))")
                }
                var targets: [AppTarget] = []
                for reference in references {
                    let path = URL(fileURLWithPath: schemeBase + "/" + reference.container).standardizedFileURL.path
                    guard path.hasSuffix(".xcodeproj") else { continue }      // a package's product: never an app
                    guard let project = projects.first(where: { $0.path == path }) ?? XcodeProjectFile.read(path) else {
                        throw Unreadable(reason: "scheme \"\(name)\" builds \(reference.name) in \(relative(path)), which could not be read")
                    }
                    guard let target = project.targets.first(where: { $0.id == reference.id })
                            ?? project.targets.first(where: { $0.name == reference.name }) else {
                        throw Unreadable(reason: "scheme \"\(name)\" builds \(reference.name), which \(relative(path)) doesn't have")
                    }
                    built[path, default: []].formUnion([target.id, target.name])
                    targets.append(target.appTarget)
                    if target.isApp { apps.append(target) }
                }
                schemes.append(Scheme(name: name, targets: targets))
            }
        }

        if Self.autocreatesSchemes(settingsFile) {
            // Xcode makes a scheme for each target no scheme builds, except test bundles (a scheme tests them).
            for project in projects {
                for target in project.targets where !target.isTest && !built[project.path, default: []].contains(target.id) {
                    guard !taken(target.name) else { continue }
                    schemes.append(Scheme(name: target.name, targets: [target.appTarget]))
                    if target.isApp { apps.append(target) }
                }
            }
            // And for local packages: a package reference gets a scheme per product; a package folder in the project
            // navigator (or the workspace) also one per executable, and per test target no product's scheme tests.
            var styles: [(folder: String, style: PackageLayout.Style)] = packageFolders.map { ($0, .folder) }
            for project in projects {
                styles += project.packageFolders.map { ($0, .folder) }
                styles += project.localPackages.map { ($0, .packageReference) }
            }
            var unique: [(folder: String, style: PackageLayout.Style)] = []
            for entry in styles {
                if let index = unique.firstIndex(where: { $0.folder == entry.folder }) {
                    if entry.style == .folder { unique[index].style = .folder }
                } else {
                    unique.append(entry)
                }
            }
            let manifests = unique.map { (folder: $0.folder, style: $0.style, label: relative($0.folder) + "/Package.swift") }
            if !manifests.isEmpty {
                let count = manifests.count == 1 ? "1 local Swift package" : "\(manifests.count) local Swift packages"
                let names = try await progress.step("reading the Package.swift of \(count) with `swift package dump-package`…",
                                                    done: "read the Package.swift of \(count)") {
                    try await packageSchemes(manifests)
                }
                for name in names where !taken(name) { schemes.append(Scheme(name: name, targets: [])) }
            }
        }

        schemes.sort { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
        guard !apps.isEmpty else { throw Unreadable(reason: "no scheme in the project files builds an app") }
        if let unknown = apps.first(where: { $0.unknown != nil }), let reason = unknown.unknown {
            throw Unreadable(reason: "the project files don't say which platform \(unknown.name) builds for (\(reason))")
        }
        return .confident(schemes)
    }

    /// The packages' scheme names, in order, each manifest read with `swift package dump-package` side by side.
    /// `label` names the manifest in a failure.
    func packageSchemes(_ packages: [(folder: String, style: PackageLayout.Style, label: String)]) async throws -> [String] {
        let results = await withTaskGroup(of: (Int, Result<[String], Unreadable>).self) { group in
            for (index, package) in packages.enumerated() {
                group.addTask {
                    let dump = Self.dumpPackage(in: package.folder, scratchPath: scratch + "/swiftpm-\(index)", developerDir: developerDir)
                    let manifest = package.label
                    do {
                        let output = try await runner.run(dump)
                        guard output.succeeded else {
                            let detail = output.stderrString.split(separator: "\n").last { $0.contains("error:") }
                            return (index, .failure(Unreadable(reason: "could not read \(manifest) (`swift package dump-package` exit "
                                                                    + "\(output.exitCode)" + (detail.map { ": " + $0 } ?? "") + ")")))
                        }
                        let layout = try PackageLayout.parse(output.stdout)
                        return (index, .success(layout.schemes(as: package.style)))
                    } catch {
                        return (index, .failure(Unreadable(reason: "could not read \(manifest) (\(error))")))
                    }
                }
            }
            var results: [Int: Result<[String], Unreadable>] = [:]
            for await (index, result) in group { results[index] = result }
            return results
        }
        return try packages.indices.flatMap { try results[$0]!.get() }
    }

    /// `swift package dump-package`, which evaluates the manifest and fetches nothing. PATH holds no git: SwiftPM
    /// would otherwise run `git describe`, `rev-parse`, and `status` in the package's repository (the user's
    /// project), and `git status` can rewrite the index, racing the user's own git commands.
    static func dumpPackage(in folder: String, scratchPath: String, developerDir: String?) -> Invocation {
        var dump = Invocation.xcrun(["swift", "package", "--scratch-path", scratchPath, "dump-package"],
                                    developerDir: developerDir, timeout: .seconds(120))
        dump.workingDirectory = folder
        dump.environment["PATH"] = "/var/empty"
        return dump
    }

    /// The shared schemes folder, then each user's.
    static func schemeFolders(in container: String) -> [String] {
        let users = files(in: container + "/xcuserdata", ending: ".xcuserdatad")
        return [container + "/xcshareddata/xcschemes"] + users.map { container + "/xcuserdata/" + $0 + "/xcschemes" }
    }

    static func files(in folder: String, ending suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(suffix) }.sorted()
    }

    /// Xcode creates schemes for targets and packages unless the shared workspace settings turn it off.
    static func autocreatesSchemes(_ settingsFile: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsFile),
              let settings = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = settings["IDEWorkspaceSharedSettings_AutocreateContextsIfNeeded"] as? Bool else { return true }
        return value
    }
}

/// The targets and local packages in a project.pbxproj, an old-style (OpenStep) property list.
struct XcodeProjectFile: Sendable {
    /// The .xcodeproj, standardized.
    let path: String
    let targets: [Target]
    /// Folders of `XCLocalSwiftPackageReference`s.
    let localPackages: [String]
    /// Folder references in the project navigator that hold a Package.swift.
    let packageFolders: [String]

    struct Target: Sendable {
        let id: String
        let name: String
        let productType: String
        let platforms: [AppPlatform]
        let deviceFamilies: [Int]
        /// Why `platforms` (or, for an iOS app, `deviceFamilies`) isn't known; nil when it is.
        let unknown: String?

        var isApp: Bool { productType.hasPrefix("com.apple.product-type.application") }
        var isTest: Bool {
            productType.hasPrefix("com.apple.product-type.bundle.unit-test") || productType.hasPrefix("com.apple.product-type.bundle.ui-testing")
        }
        var appTarget: AppTarget { AppTarget(name: name, isApp: isApp, platforms: platforms, deviceFamilies: deviceFamilies) }
    }

    static func read(_ path: String) -> XcodeProjectFile? {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let data = FileManager.default.contents(atPath: path + "/project.pbxproj"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String, let root = objects[rootID] else { return nil }
        let projectDir = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
            .appendingPathComponent(root["projectDirPath"] as? String ?? "").standardizedFileURL.path
        func configurations(_ listID: Any?) -> [[String: Any]] {
            guard let id = listID as? String, let ids = objects[id]?["buildConfigurations"] as? [String] else { return [] }
            return ids.compactMap { objects[$0] }
        }
        let projectConfigurations = configurations(root["buildConfigurationList"])
        func folder(_ relative: String) -> String {
            URL(fileURLWithPath: projectDir).appendingPathComponent(relative).standardizedFileURL.path
        }
        let localPackages = objects.values.filter { $0["isa"] as? String == "XCLocalSwiftPackageReference" }
            .compactMap { $0["relativePath"] as? String }.map(folder).sorted()

        // Folder references: their path is relative to their group's, up to the main group (the project folder).
        var parents: [String: String] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] { parents[child] = id }
        }
        func location(of id: String, depth: Int = 0) -> String? {
            guard depth < 64, let object = objects[id] else { return nil }
            let own = object["path"] as? String
            switch object["sourceTree"] as? String ?? "<group>" {
            case "SOURCE_ROOT": return folder(own ?? "")
            case "<absolute>": return own
            case "<group>":
                let parent = parents[id].map { location(of: $0, depth: depth + 1) } ?? projectDir
                guard let parent else { return nil }
                return own.map { URL(fileURLWithPath: parent).appendingPathComponent($0).standardizedFileURL.path } ?? parent
            default: return nil
            }
        }
        // A configuration's .xcconfig: a file reference, or (in synchronized folders) a folder and a path in it.
        func baseFile(_ configuration: [String: Any]) -> String? {
            if let id = configuration["baseConfigurationReference"] as? String { return location(of: id) ?? "" }
            if let anchor = configuration["baseConfigurationReferenceAnchor"] as? String {
                guard let folder = location(of: anchor),
                      let path = configuration["baseConfigurationReferenceRelativePath"] as? String else { return "" }
                return URL(fileURLWithPath: folder).appendingPathComponent(path).standardizedFileURL.path
            }
            return nil
        }
        let targets: [Target] = (root["targets"] as? [String] ?? []).compactMap { id in
            guard let object = objects[id], let name = object["name"] as? String else { return nil }
            let productType = object["productType"] as? String ?? ""
            let settings = BuildSettingLevels(target: configurations(object["buildConfigurationList"]), project: projectConfigurations,
                                              baseFile: baseFile)
            let runsOn = settings.platforms(isApp: productType.hasPrefix("com.apple.product-type.application"))
            return Target(id: id, name: name, productType: productType, platforms: runsOn.platforms,
                          deviceFamilies: runsOn.families, unknown: runsOn.unknown)
        }
        let packageFolders = objects.filter { _, object in
            object["isa"] as? String == "PBXFileReference"
                && (object["lastKnownFileType"] as? String == "folder" || object["explicitFileType"] as? String == "folder")
        }.compactMap { location(of: $0.key) }
            .filter { FileManager.default.fileExists(atPath: $0 + "/Package.swift") }.sorted()
        return XcodeProjectFile(path: path, targets: targets, localPackages: localPackages, packageFolders: packageFolders)
    }
}

/// A target's build configurations and the project's, in the order Xcode applies them: the target's settings, the
/// target's .xcconfig, the project's settings, the project's .xcconfig. Plain `KEY = value` lines of .xcconfig files
/// (and the files they include) are read; values with `$(…)`, settings with SDK or architecture variants, and files
/// that can't be read leave a setting unknown.
struct BuildSettingLevels {
    let target: [[String: Any]]
    let project: [[String: Any]]
    /// The .xcconfig file a configuration is based on: nil without one, "" when its path can't be worked out.
    let baseFile: ([String: Any]) -> String?

    enum Value: Equatable { case set(String), absent, unknown(String) }

    func value(_ key: String, configuration: [String: Any]) -> Value {
        let name = configuration["name"] as? String
        let projectLevel = project.first { $0["name"] as? String == name }
        for level in [configuration, projectLevel].compactMap({ $0 }) {
            let settings = (level["buildSettings"] as? [String: Any] ?? [:]).mapValues { raw in
                (raw as? String) ?? (raw as? [String])?.joined(separator: " ") ?? "\(raw)"
            }
            if let found = Self.lookup(key, in: settings, source: nil) { return found }
            guard let file = baseFile(level) else { continue }
            let label = URL(fileURLWithPath: file).lastPathComponent
            guard !file.isEmpty else { return .unknown("its \(key) may come from an .xcconfig file that couldn't be found") }
            switch Xcconfig.settings(file) {
            case .failure(let problem): return .unknown("its \(key) may come from \(label), \(problem.reason)")
            case .success(let settings): if let found = Self.lookup(key, in: settings, source: label) { return found }
            }
        }
        return .absent
    }

    /// `key` at one level: a plain value, unknown when it's an expression or has SDK/arch variants, nil when unset.
    static func lookup(_ key: String, in settings: [String: String], source: String?) -> Value? {
        let place = source.map { " in \($0)" } ?? ""
        if settings.keys.contains(where: { $0.hasPrefix(key + "[") }) {
            return .unknown("its \(key)\(place) depends on the SDK or architecture")
        }
        guard let value = settings[key] else { return nil }
        return value.contains("$") ? .unknown("its \(key) is \(value)\(place)") : .set(value)
    }

    /// Where the target runs in every configuration, or why that isn't known (also when configurations disagree).
    /// Device families matter only for an iOS app; elsewhere they are reported when set and never make it unknown.
    func platforms(isApp: Bool) -> (platforms: [AppPlatform], families: [Int], unknown: String?) {
        var seen: (platforms: [AppPlatform], families: [Int])?
        for configuration in target {
            let platforms: [AppPlatform]
            switch value("SUPPORTED_PLATFORMS", configuration: configuration) {
            case .set(let list):
                platforms = Set(list.split(separator: " ").compactMap { AppPlatform(sdk: String($0)) }).sorted()
                if platforms.isEmpty { return ([], [], "its SUPPORTED_PLATFORMS is \(list)") }
            case .unknown(let reason): return ([], [], reason)
            case .absent:
                switch value("SDKROOT", configuration: configuration) {
                case .set(let sdk):
                    // "iphoneos", or with a version: "iphoneos18.0".
                    guard let platform = AppPlatform(sdk: String(sdk.prefix { $0.isLetter })) else {
                        return ([], [], "its SDKROOT is \(sdk)")
                    }
                    platforms = [platform]
                case .unknown(let reason): return ([], [], reason)
                case .absent: return ([], [], "it sets no SDKROOT")
                }
            }
            var families: [Int] = []
            switch value("TARGETED_DEVICE_FAMILY", configuration: configuration) {
            case .set(let list):
                families = list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            case .unknown(let reason):
                if isApp && platforms.contains(.iOS) { return ([], [], reason) }
            case .absent:
                if platforms.contains(.iOS) { families = [1] }               // the iOS SDK's default: iPhone
            }
            if let seen, seen != (platforms, families) {
                return ([], [], "its build configurations build for different devices")
            }
            seen = (platforms, families)
        }
        guard let seen else { return ([], [], "it has no build configurations") }
        return (seen.platforms, seen.families, nil)
    }
}

/// The settings in an .xcconfig file and the files it includes, later lines winning.
enum Xcconfig {
    static func settings(_ path: String, depth: Int = 0) -> Result<[String: String], ProjectFileReader.Unreadable> {
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard depth < 16 else { return .failure(.init(reason: "which includes too many files deep")) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .failure(.init(reason: "which couldn't be read")) }
        var settings: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#include") {
                let optional = line.hasPrefix("#include?")
                guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else {
                    return .failure(.init(reason: "which includes a file in a way xcd doesn't read (\(name): \(line))"))
                }
                let included = String(line[line.index(after: open)..<close])
                guard !included.hasPrefix("<") else { return .failure(.init(reason: "which includes \(included)")) }
                let target = included.hasPrefix("/") ? included
                    : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(included).standardizedFileURL.path
                if optional && !FileManager.default.fileExists(atPath: target) { continue }
                switch Self.settings(target, depth: depth + 1) {
                case .failure(let problem): return .failure(problem)
                case .success(let more): settings.merge(more) { $1 }
                }
                continue
            }
            guard !line.hasPrefix("//"), let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...])
            if let comment = value.range(of: "//") { value = String(value[..<comment.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value = String(value.dropLast()).trimmingCharacters(in: .whitespaces) }
            if !key.isEmpty { settings[key] = value }
        }
        return .success(settings)
    }
}

/// The BuildableReferences of a scheme's build action, in order.
enum SchemeFile {
    struct Buildable: Sendable, Equatable {
        let id: String
        let name: String
        /// ReferencedContainer without "container:", relative to the folder holding the project or workspace.
        let container: String
    }

    static func buildables(_ path: String) -> [Buildable]? {
        guard let parser = XMLParser(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.buildables
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var buildables: [Buildable] = []
        var inBuildAction = false

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if element == "BuildAction" { inBuildAction = true }
            guard inBuildAction, element == "BuildableReference", let container = attributes["ReferencedContainer"],
                  container.hasPrefix("container:") else { return }
            buildables.append(Buildable(id: attributes["BlueprintIdentifier"] ?? "", name: attributes["BlueprintName"] ?? "",
                                        container: String(container.dropFirst("container:".count))))
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "BuildAction" { inBuildAction = false }
        }
    }
}

/// The projects and package folders a workspace's contents.xcworkspacedata lists, including inside groups.
enum WorkspaceContents {
    static func read(_ workspace: String, relativeTo base: String) throws -> (projects: [String], packageFolders: [String]) {
        let file = workspace + "/contents.xcworkspacedata"
        let relative = String(file.dropFirst(base.count + 1))
        guard let parser = XMLParser(contentsOf: URL(fileURLWithPath: file)) else {
            throw ProjectFileReader.Unreadable(reason: "could not read \(relative)")
        }
        let delegate = Delegate(base: base)
        parser.delegate = delegate
        guard parser.parse() else { throw ProjectFileReader.Unreadable(reason: "could not read \(relative)") }
        var projects: [String] = []
        var packages: [String] = []
        for path in delegate.references {
            if path.hasSuffix(".xcodeproj") {
                projects.append(path)
            } else if FileManager.default.fileExists(atPath: path + "/Package.swift") {
                packages.append(path)
            }
        }
        return (projects, packages)
    }

    final class Delegate: NSObject, XMLParserDelegate {
        let base: String
        var groups: [String]
        var references: [String] = []

        init(base: String) {
            self.base = base
            groups = [base]
        }

        func resolve(_ location: String?) -> String? {
            guard let location, let colon = location.firstIndex(of: ":") else { return nil }
            let path = String(location[location.index(after: colon)...])
            let parent: String
            switch location[..<colon] {
            case "group": parent = groups.last ?? base
            case "container": parent = base
            case "absolute": return URL(fileURLWithPath: path).standardizedFileURL.path
            default: return nil                                              // "self:" and the like
            }
            return URL(fileURLWithPath: parent).appendingPathComponent(path).standardizedFileURL.path
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch element {
            case "Group": groups.append(resolve(attributes["location"]) ?? groups.last ?? base)
            case "FileRef": if let path = resolve(attributes["location"]) { references.append(path) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "Group", groups.count > 1 { groups.removeLast() }
        }
    }
}

/// A package's products and targets from `swift package dump-package`, for the schemes Xcode gives it.
public struct PackageLayout: Sendable, Equatable {
    public enum Style: Sendable, Equatable {
        /// The project is the package (Package.swift at the root).
        case root
        /// An `XCLocalSwiftPackageReference` in a project.
        case packageReference
        /// A package folder in a project's navigator or a workspace.
        case folder
    }

    struct Product: Sendable, Equatable { let name: String; let targets: [String]; let kind: String }
    struct Target: Sendable, Equatable { let name: String; let kind: String; let dependencies: [String] }

    let name: String
    let products: [Product]
    let targets: [Target]

    public static func parse(_ data: Data) throws -> PackageLayout {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = json["name"] as? String else {
            throw XcdError(.subprocessFailed, "could not read `swift package dump-package` output",
                           next: "run `swift package dump-package` in the package folder to check Package.swift")
        }
        let products = (json["products"] as? [[String: Any]] ?? []).compactMap { product -> Product? in
            guard let name = product["name"] as? String else { return nil }
            let kind = (product["type"] as? [String: Any])?.keys.first ?? ""
            return Product(name: name, targets: product["targets"] as? [String] ?? [], kind: kind)
        }
        let targets = (json["targets"] as? [[String: Any]] ?? []).compactMap { target -> Target? in
            guard let name = target["name"] as? String else { return nil }
            // Same-package dependencies: {"byName": [name, condition]} or {"target": [name, condition]}.
            let dependencies = (target["dependencies"] as? [[String: Any]] ?? []).compactMap { dependency -> String? in
                ((dependency["byName"] ?? dependency["target"]) as? [Any])?.first as? String
            }
            return Target(name: name, kind: target["type"] as? String ?? "", dependencies: dependencies)
        }
        return PackageLayout(name: name, products: products, targets: targets)
    }

    /// The schemes Xcode lists for the package, as observed with Xcode 27:
    /// - at the root: a scheme per product (executable targets are products there too), plus "<name>-Package"
    ///   when that makes more than one; a single scheme is named for the package;
    /// - as a package reference: a scheme per product;
    /// - as a folder: also a scheme per executable target, and per test target that tests no product's target.
    public func schemes(as style: Style) -> [String] {
        let declared = products.filter { $0.kind != "plugin" }.map(\.name)
        let executables = targets.filter { $0.kind == "executable" && !declared.contains($0.name) }.map(\.name)
        switch style {
        case .root:
            let all = declared + executables
            return all.count > 1 ? all + [name + "-Package"] : [name]
        case .packageReference:
            return declared
        case .folder:
            let productTargets = Set(products.flatMap(\.targets))
            let tests = targets.filter { $0.kind == "test" && !$0.dependencies.contains(where: productTargets.contains) }.map(\.name)
            return declared + executables + tests
        }
    }
}
