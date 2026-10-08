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

    /// Throws only when cancelled (Ctrl-C), which ends detection rather than sending it to xcodebuild.
    public func read(_ container: ProjectContainer) async throws -> Outcome {
        do {
            return try await readFiles(container)
        } catch is CancellationError {
            throw CancellationError()
        } catch let unreadable as Unreadable {
            try Task.checkCancellation()
            return .unsure(unreadable.reason)
        } catch {
            try Task.checkCancellation()
            return .unsure("could not read the project files (\(error))")
        }
    }

    struct Unreadable: Error { let reason: String }

    /// The schemes the files give the container: those of its scheme files, then, unless the workspace settings
    /// turn autocreation off, the ones Xcode makes itself for targets and local packages (`SchemeList`).
    func readFiles(_ container: ProjectContainer) async throws -> Outcome {
        let files = try ContainerFiles.read(container)
        var list = SchemeList()
        try list.addSchemeFiles(of: files)
        if Self.autocreatesSchemes(files.settingsFile) {
            for project in files.projects { try list.addAutocreated(for: project, named: files.relative(project.path)) }
            list.addPackageSchemes(try await packageSchemes(files.localPackages))
        }
        return .confident(try list.confident())
    }

    /// The packages' scheme names, in order. Reading their manifests is the one step that runs anything, so it is shown.
    func packageSchemes(_ packages: [LocalPackage]) async throws -> [String] {
        guard !packages.isEmpty else { return [] }
        let count = packages.count == 1 ? "1 local Swift package" : "\(packages.count) local Swift packages"
        return try await progress.step("reading the Package.swift of \(count) with `swift package dump-package`…",
                                       done: "read the Package.swift of \(count)") {
            try await readManifests(packages)
        }
    }

    /// Each manifest read with `swift package dump-package`, side by side. The first package that can't be read
    /// (in the packages' order) is the failure.
    func readManifests(_ packages: [LocalPackage]) async throws -> [String] {
        let results = await withTaskGroup(of: (Int, Result<[String], any Error>).self) { group in
            for (index, package) in packages.enumerated() {
                group.addTask { (index, await schemes(of: package, scratchPath: scratch + "/swiftpm-\(index)")) }
            }
            var results = [Result<[String], any Error>?](repeating: nil, count: packages.count)
            for await (index, result) in group { results[index] = result }
            return results.compactMap { $0 }
        }
        return try results.flatMap { try $0.get() }
    }

    /// One package's scheme names, or why its manifest couldn't be read.
    func schemes(of package: LocalPackage, scratchPath: String) async -> Result<[String], any Error> {
        let dump = Self.dumpPackage(in: package.folder, scratchPath: scratchPath, developerDir: developerDir)
        do {
            let output = try await runner.run(dump)
            guard output.succeeded else {
                let detail = output.stderrString.split(separator: "\n").last { $0.contains("error:") }
                return .failure(Unreadable(reason: "could not read \(package.label) (`swift package dump-package` exit "
                                           + "\(output.exitCode)" + (detail.map { ": " + $0 } ?? "") + ")"))
            }
            return .success(try PackageLayout.parse(output.stdout).schemes(as: package.style))
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            return .failure(Unreadable(reason: "could not read \(package.label) (\(error))"))
        }
    }

    /// `swift package dump-package`, which evaluates the manifest and fetches nothing. PATH holds no git: SwiftPM
    /// would otherwise run `git describe`, `rev-parse`, and `status` in the package's repository (the user's
    /// project), and `git status` can rewrite the index, racing the user's own git commands. So the manifest sees
    /// `Context.gitInformation` as nil; one that declares products depending on it could list others than in Xcode.
    static func dumpPackage(in folder: String, scratchPath: String, developerDir: String?) -> Invocation {
        var dump = Invocation.xcrun(["swift", "package", "--scratch-path", scratchPath, "dump-package"],
                                    developerDir: developerDir, timeout: .seconds(120))
        dump.workingDirectory = folder
        dump.environment["PATH"] = "/var/empty"
        return dump
    }

    /// The shared schemes folder, then this user's. Like xcodebuild, other users' schemes (committed by mistake)
    /// are not read.
    static func schemeFolders(in container: String, user: String = NSUserName()) -> [String] {
        [container + "/xcshareddata/xcschemes", container + "/xcuserdata/" + user + ".xcuserdatad/xcschemes"]
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
    /// Other projects this one references (subprojects), standardized.
    let referencedProjects: [String]

    enum Dependency: Sendable, Equatable {
        /// A target in the same project, by ID.
        case target(String)
        /// A target in another project (a subproject's).
        case elsewhere
    }

    struct Target: Sendable {
        let id: String
        let name: String
        let productType: String
        let platforms: [AppPlatform]
        let deviceFamilies: [Int]
        /// Why `platforms` (or, for an iOS app, `deviceFamilies`) isn't known; nil when it is.
        let unknown: String?
        /// The targets it depends on (a test bundle on its host app, say).
        let dependencies: [Dependency]

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
              let objects = PBXObjects(plist, projectAt: path) else { return nil }
        let packageFolders = objects.fileReferences(ofType: "folder")
            .filter { FileManager.default.fileExists(atPath: $0 + "/Package.swift") }.sorted()
        return XcodeProjectFile(path: path, targets: objects.targets, localPackages: objects.localPackages,
                                packageFolders: packageFolders,
                                referencedProjects: objects.fileReferences(ofType: "wrapper.pb-project"))
    }
}

/// The settings in an .xcconfig file and the files it includes, later lines winning.
enum Xcconfig {
    static func settings(_ path: String, depth: Int = 0) -> Result<[String: String], ProjectFileReader.Unreadable> {
        guard depth < 16 else { return .failure(.init(reason: "which includes too many files deep")) }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .failure(.init(reason: "which couldn't be read")) }
        var settings: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#include") {
                let optional = line.hasPrefix("#include?")
                let target: String
                switch includedFile(line, from: path) {
                case .failure(let problem): return .failure(problem)
                case .success(let file): target = file
                }
                if optional && !FileManager.default.fileExists(atPath: target) { continue }
                switch Self.settings(target, depth: depth + 1) {
                case .failure(let problem): return .failure(problem)
                case .success(let more): settings.merge(more) { $1 }
                }
            } else if let (key, value) = assignment(line) {
                settings[key] = value
            }
        }
        return .success(settings)
    }

    /// The file an `#include "…"` line of the file at `path` names, relative to that file's folder unless absolute.
    static func includedFile(_ line: String, from path: String) -> Result<String, ProjectFileReader.Unreadable> {
        guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return .failure(.init(reason: "which includes a file in a way xcd doesn't read (\(name): \(line))"))
        }
        let included = String(line[line.index(after: open)..<close])
        guard !included.hasPrefix("<") else { return .failure(.init(reason: "which includes \(included)")) }
        return .success(included.hasPrefix("/") ? included
            : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(included).standardizedFileURL.path)
    }

    /// The setting a `KEY = value` line makes, without the comment or the semicolon after it; nil for any other line.
    static func assignment(_ line: String) -> (key: String, value: String)? {
        guard !line.hasPrefix("//"), let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        var value = String(line[line.index(after: equals)...])
        if let comment = value.range(of: "//") { value = String(value[..<comment.lowerBound]) }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(";") { value = String(value.dropLast()).trimmingCharacters(in: .whitespaces) }
        return key.isEmpty ? nil : (key, value)
    }
}

/// The BuildableReferences of a scheme's build action, in order, and of its test action's Testables.
enum SchemeFile {
    struct Buildable: Sendable, Equatable {
        let id: String
        let name: String
        /// ReferencedContainer without "container:", relative to the folder holding the project or workspace.
        let container: String
    }

    static func read(_ path: String) -> (built: [Buildable], tested: [Buildable])? {
        guard let parser = XMLParser(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return (delegate.built, delegate.tested)
    }

    final class Delegate: NSObject, XMLParserDelegate {
        var built: [Buildable] = []
        var tested: [Buildable] = []
        var inBuildAction = false
        var inTestables = false

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if element == "BuildAction" { inBuildAction = true }
            if element == "Testables" { inTestables = true }
            guard inBuildAction || inTestables, element == "BuildableReference",
                  let container = attributes["ReferencedContainer"], container.hasPrefix("container:") else { return }
            let buildable = Buildable(id: attributes["BlueprintIdentifier"] ?? "", name: attributes["BlueprintName"] ?? "",
                                      container: String(container.dropFirst("container:".count)))
            if inBuildAction { built.append(buildable) } else { tested.append(buildable) }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "BuildAction" { inBuildAction = false }
            if element == "Testables" { inTestables = false }
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

/// A Mac Catalyst app runs in the iOS simulator, so xcd counts it as an iOS app, whether the project files say
/// SUPPORTS_MACCATALYST or `-showBuildSettings` (with no destination) reports its Mac variant.
enum Catalyst {
    /// TARGETED_DEVICE_FAMILY's Mac Catalyst value; no simulator has it.
    static let deviceFamily = 6

    static func asIOS(_ platforms: [AppPlatform]) -> [AppPlatform] {
        Set(platforms.filter { $0 != .macOS } + [.iOS]).sorted()
    }
}
