import Foundation

/// A local package whose schemes Xcode lists beside the project's.
struct LocalPackage: Sendable {
    let folder: String
    /// How the project holds it: a folder shows more schemes than a package reference does.
    var style: PackageLayout.Style
    /// Its manifest as a failure names it.
    let label: String
}

/// What a project or workspace consists of: its projects, the package folders a workspace lists, and where its
/// scheme files are.
struct ContainerFiles {
    typealias Unreadable = ProjectFileReader.Unreadable

    /// The folder that holds the container. Messages give paths relative to it.
    let base: String
    /// The container, relative to `base`.
    let name: String
    let settingsFile: String
    var projects: [XcodeProjectFile] = []
    /// Package folders a workspace lists.
    var packageFolders: [String] = []
    /// Scheme folders in the order they are read, each with the folder its schemes' containers are relative to.
    var schemeFolders: [(folder: String, base: String)] = []

    init(path: String, settingsFile: String) {
        base = (path as NSString).deletingLastPathComponent
        name = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
        self.settingsFile = settingsFile
    }

    /// A workspace's own scheme folders come before its projects'.
    static func read(_ container: ProjectContainer) throws -> ContainerFiles {
        switch container {
        case .package:
            throw Unreadable(reason: "a Swift package has no project files")
        case .project(let path):
            var files = ContainerFiles(path: path, settingsFile: path + "/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings")
            try files.add(projects: [path])
            return files
        case .workspace(let path):
            var files = ContainerFiles(path: path, settingsFile: path + "/xcshareddata/WorkspaceSettings.xcsettings")
            let members = try WorkspaceContents.read(path, relativeTo: files.base)
            files.packageFolders = members.packageFolders
            files.schemeFolders = ProjectFileReader.schemeFolders(in: path).map { ($0, files.base) }
            try files.add(projects: members.projects)
            return files
        }
    }

    mutating func add(projects paths: [String]) throws {
        for path in paths {
            guard let project = XcodeProjectFile.read(path) else {
                throw Unreadable(reason: "could not read \(relative(path))/project.pbxproj")
            }
            projects.append(project)
            schemeFolders += ProjectFileReader.schemeFolders(in: path).map { ($0, (path as NSString).deletingLastPathComponent) }
        }
    }

    func relative(_ path: String) -> String {
        path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    /// The target a scheme's build action names, in the project at `path`. A scheme may name any project, but
    /// xcodebuild builds only the container's projects and those they reference.
    func target(_ reference: SchemeFile.Buildable, in path: String, builtBy scheme: String) throws -> XcodeProjectFile.Target {
        let what = "scheme \"\(scheme)\" builds \(reference.name)"
        guard projects.contains(where: { $0.path == path || $0.referencedProjects.contains(path) }) else {
            throw Unreadable(reason: "\(what) in \(relative(path)), which \(name) doesn't include")
        }
        guard let project = projects.first(where: { $0.path == path }) ?? XcodeProjectFile.read(path) else {
            throw Unreadable(reason: "\(what) in \(relative(path)), which could not be read")
        }
        guard let target = project.targets.first(where: { $0.id == reference.id })
                ?? project.targets.first(where: { $0.name == reference.name }) else {
            throw Unreadable(reason: "\(what), which \(relative(path)) doesn't have")
        }
        return target
    }

    /// The local packages Xcode makes schemes for: a package reference gets a scheme per product; a package folder
    /// in the project navigator (or the workspace) also one per executable, and per test target no product's scheme
    /// tests. A folder that is both counts as a folder.
    var localPackages: [LocalPackage] {
        var styles: [(folder: String, style: PackageLayout.Style)] = packageFolders.map { ($0, .folder) }
        for project in projects {
            styles += project.packageFolders.map { ($0, .folder) }
            styles += project.localPackages.map { ($0, .packageReference) }
        }
        var unique: [LocalPackage] = []
        for entry in styles {
            if let index = unique.firstIndex(where: { $0.folder == entry.folder }) {
                if entry.style == .folder { unique[index].style = .folder }
            } else {
                unique.append(LocalPackage(folder: entry.folder, style: entry.style, label: relative(entry.folder) + "/Package.swift"))
            }
        }
        return unique
    }
}

/// The schemes found so far, with what the scheme files build and test.
struct SchemeList {
    typealias Scheme = ProjectFileReader.Scheme
    typealias Unreadable = ProjectFileReader.Unreadable

    var schemes: [Scheme] = []
    /// Project path → the blueprint IDs and names some scheme file builds.
    var built: [String: Set<String>] = [:]
    /// Project path → the blueprint IDs and names some scheme file tests.
    var tested: [String: Set<String>] = [:]
    /// The app targets a scheme builds.
    var apps: [XcodeProjectFile.Target] = []

    func taken(_ name: String) -> Bool { schemes.contains { $0.name == name } }

    /// Reads the container's scheme files, folder by folder. The first file with a name has that name.
    mutating func addSchemeFiles(of files: ContainerFiles) throws {
        for (folder, schemeBase) in files.schemeFolders {
            for file in ProjectFileReader.files(in: folder, ending: ".xcscheme") {
                let name = String(file.dropLast(".xcscheme".count))
                guard !taken(name) else { continue }
                guard let references = SchemeFile.read(folder + "/" + file) else {
                    throw Unreadable(reason: "could not read \(files.relative(folder + "/" + file))")
                }
                try add(name, references, relativeTo: schemeBase, files)
            }
        }
    }

    /// Adds the scheme a scheme file describes: what it tests, and the targets its build action builds, in order.
    mutating func add(_ name: String, _ references: (built: [SchemeFile.Buildable], tested: [SchemeFile.Buildable]),
                      relativeTo schemeBase: String, _ files: ContainerFiles) throws {
        func project(_ reference: SchemeFile.Buildable) -> String {
            URL(fileURLWithPath: schemeBase + "/" + reference.container).standardizedFileURL.path
        }
        for reference in references.tested {
            tested[project(reference), default: []].formUnion([reference.id, reference.name])
        }
        var targets: [AppTarget] = []
        for reference in references.built {
            let path = project(reference)
            guard path.hasSuffix(".xcodeproj") else { continue }      // a package's product: never an app
            let target = try files.target(reference, in: path, builtBy: name)
            built[path, default: []].formUnion([target.id, target.name])
            targets.append(target.appTarget)
            if target.isApp { apps.append(target) }
        }
        schemes.append(Scheme(name: name, targets: targets))
    }

    /// Xcode makes a scheme for each target no scheme file builds. A test bundle gets one too, unless a scheme file
    /// builds or tests it, or it depends on a target that gets an autocreated scheme (which then tests it): the
    /// rule observed with Xcode 27 (ProjectFilesParityTests pins each case). Where the files can't tell which
    /// applies, this throws, and tier 1 asks xcodebuild.
    mutating func addAutocreated(for project: XcodeProjectFile, named projectName: String) throws {
        var made = AutocreatedTargets(project: project, projectName: projectName)
        for target in project.targets where !target.isTest && !built[project.path, default: []].contains(target.id) {
            guard !taken(target.name) else { made.shadowed.insert(target.id); continue }
            schemes.append(Scheme(name: target.name, targets: [target.appTarget]))
            made.targets.insert(target.id)
            if target.isApp { apps.append(target) }
        }
        let covered = built[project.path, default: []].union(tested[project.path, default: []])
        for test in project.targets where test.isTest && !covered.contains(test.id) && !covered.contains(test.name) {
            let absorbed = try made.absorbs(test)
            if !absorbed && !taken(test.name) { schemes.append(Scheme(name: test.name, targets: [test.appTarget])) }
        }
    }

    /// Local packages' schemes build no target of the project.
    mutating func addPackageSchemes(_ names: [String]) {
        for name in names where !taken(name) { schemes.append(Scheme(name: name, targets: [])) }
    }

    /// Every scheme, sorted as `xcodebuild -list` sorts them. The files are enough only when some scheme builds an
    /// app and the platform of every app a scheme builds is known.
    func confident() throws -> [Scheme] {
        guard !apps.isEmpty else { throw Unreadable(reason: "no scheme in the project files builds an app") }
        if let unknown = apps.first(where: { $0.unknown != nil }), let reason = unknown.unknown {
            throw Unreadable(reason: "the project files don't say which platform \(unknown.name) builds for (\(reason))")
        }
        return schemes.sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
    }
}

/// The targets of one project that got an autocreated scheme, and those left without one because a scheme file
/// already has their name.
struct AutocreatedTargets {
    let project: XcodeProjectFile
    /// The project as messages name it.
    let projectName: String
    var targets: Set<String> = []
    /// No scheme file builds it, but one already has its name.
    var shadowed: Set<String> = []

    /// Whether a target with an autocreated scheme tests `test`, which then gets no scheme of its own. Throws when
    /// the project files can't tell.
    func absorbs(_ test: XcodeProjectFile.Target) throws -> Bool {
        func unsure(_ why: String) -> ProjectFileReader.Unreadable {
            .init(reason: "the project files don't say whether \(test.name) gets a scheme of its own (it depends on \(why))")
        }
        var absorbed = false
        for dependency in test.dependencies {
            guard case .target(let id) = dependency else { throw unsure("a target in another project") }
            guard let target = project.targets.first(where: { $0.id == id }) else {
                throw unsure("a target \(projectName) doesn't list")
            }
            if target.isTest { throw unsure("\(target.name), a test bundle") }
            if shadowed.contains(id) { throw unsure("\(target.name), whose name a scheme file already has") }
            if targets.contains(id) { absorbed = true }
        }
        return absorbed
    }
}
