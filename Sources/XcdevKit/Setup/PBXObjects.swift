import Foundation

/// The objects of a project.pbxproj (an old-style property list), by ID, and what `XcodeProjectFile` reads from them.
struct PBXObjects {
    let objects: [String: [String: Any]]
    let rootID: String
    /// The PBXProject.
    let root: [String: Any]
    /// The folder the project's paths start from: the .xcodeproj's folder, moved by the project's `projectDirPath`.
    let projectDir: String
    /// Each child of a group → the group.
    let parents: [String: String]

    /// `path` is the .xcodeproj, standardized. Nil for a property list that isn't a project's.
    init?(_ plist: [String: Any], projectAt path: String) {
        guard let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String, let root = objects[rootID] else { return nil }
        self.objects = objects
        self.rootID = rootID
        self.root = root
        projectDir = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
            .appendingPathComponent(root["projectDirPath"] as? String ?? "").standardizedFileURL.path
        var parents: [String: String] = [:]
        for (id, object) in objects {
            for child in object["children"] as? [String] ?? [] { parents[child] = id }
        }
        self.parents = parents
    }

    func configurations(_ listID: Any?) -> [[String: Any]] {
        guard let id = listID as? String, let ids = objects[id]?["buildConfigurations"] as? [String] else { return [] }
        return ids.compactMap { objects[$0] }
    }

    func folder(_ relative: String) -> String {
        URL(fileURLWithPath: projectDir).appendingPathComponent(relative).standardizedFileURL.path
    }

    /// Where a file reference or group is: its path is relative to its group's, up to the main group (the project folder).
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

    /// A configuration's .xcconfig: a file reference, or (in synchronized folders) a folder and a path in it.
    /// Nil without one, "" when its path can't be worked out.
    func baseFile(_ configuration: [String: Any]) -> String? {
        if let id = configuration["baseConfigurationReference"] as? String { return location(of: id) ?? "" }
        if let anchor = configuration["baseConfigurationReferenceAnchor"] as? String {
            guard let folder = location(of: anchor),
                  let path = configuration["baseConfigurationReferenceRelativePath"] as? String else { return "" }
            return URL(fileURLWithPath: folder).appendingPathComponent(path).standardizedFileURL.path
        }
        return nil
    }

    /// A PBXTargetDependency names its target directly, or through a proxy whose container is this project or another.
    func dependency(_ id: String) -> XcodeProjectFile.Dependency {
        guard let object = objects[id] else { return .elsewhere }
        if let target = object["target"] as? String { return .target(target) }
        guard let proxyID = object["targetProxy"] as? String, let proxy = objects[proxyID],
              proxy["containerPortal"] as? String == rootID, let remote = proxy["remoteGlobalIDString"] as? String else { return .elsewhere }
        return .target(remote)
    }

    /// The project's targets, in its order, each with where it runs.
    var targets: [XcodeProjectFile.Target] {
        let projectConfigurations = configurations(root["buildConfigurationList"])
        return (root["targets"] as? [String] ?? []).compactMap { id in
            guard let object = objects[id], let name = object["name"] as? String else { return nil }
            let productType = object["productType"] as? String ?? ""
            let settings = BuildSettingLevels(target: configurations(object["buildConfigurationList"]), project: projectConfigurations,
                                              baseFile: baseFile)
            let runsOn = settings.platforms(isApp: productType.hasPrefix("com.apple.product-type.application"))
            return XcodeProjectFile.Target(id: id, name: name, productType: productType, platforms: runsOn.platforms,
                                           deviceFamilies: runsOn.families, unknown: runsOn.unknown,
                                           dependencies: (object["dependencies"] as? [String] ?? []).map(dependency))
        }
    }

    /// The folders of the project's `XCLocalSwiftPackageReference`s, sorted.
    var localPackages: [String] {
        objects.values.filter { $0["isa"] as? String == "XCLocalSwiftPackageReference" }
            .compactMap { $0["relativePath"] as? String }.map(folder).sorted()
    }

    /// Where the file references of one type are ("folder", "wrapper.pb-project"), sorted.
    func fileReferences(ofType type: String) -> [String] {
        objects.filter { _, object in
            object["isa"] as? String == "PBXFileReference"
                && (object["lastKnownFileType"] as? String == type || object["explicitFileType"] as? String == type)
        }.compactMap { location(of: $0.key) }.sorted()
    }
}
