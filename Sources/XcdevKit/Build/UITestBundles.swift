import Foundation

/// Whether a test run will drive the device's UI itself. If it will, xcd's UI runner must not be running beside it:
/// both would drive the same device.
enum UITestBundles {
    static let productType = "com.apple.product-type.bundle.ui-testing"

    /// True when the scheme's test action includes a UI-test bundle that `only` and `skip` leave in, false when it
    /// certainly includes none, and nil when xcd can't tell: the scheme has no file of its own, it uses a test plan
    /// (the plan decides what runs, whatever targets the scheme still lists), or a project it names can't be read.
    static func included(scheme: String, container: ProjectContainer, only: [String], skip: [String]) -> Bool? {
        if container.isPackage { return false }                 // a package has no UI-test bundles
        guard let file = schemeFile(scheme, in: container), !usesTestPlan(file),
              let tested = SchemeFile.read(file)?.tested, !tested.isEmpty else { return nil }
        var unsure = false
        for testable in tested where runs(testable.name, only: only, skip: skip) {
            switch isUITest(testable, relativeTo: container.workingDirectory) {
            case true?: return true
            case false?: continue
            case nil: unsure = true
            }
        }
        return unsure ? nil : false
    }

    /// Whether the scheme file names a test plan. A file that can't be read as text counts: xcd can't tell.
    static func usesTestPlan(_ file: String) -> Bool {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return true }
        return text.contains("TestPlanReference")
    }

    /// Whether `only` and `skip` (xcodebuild's `-only-testing` and `-skip-testing`) leave any of the target's tests in.
    static func runs(_ target: String, only: [String], skip: [String]) -> Bool {
        if skip.contains(target) { return false }
        return only.isEmpty || only.contains { $0 == target || $0.hasPrefix(target + "/") }
    }

    /// The scheme's file: in the container's own scheme folders, or, for a workspace, in those of its projects.
    static func schemeFile(_ scheme: String, in container: ProjectContainer) -> String? {
        var containers: [String] = []
        switch container {
        case .project(let path):
            containers = [path]
        case .workspace(let path):
            let projects = (try? WorkspaceContents.read(path, relativeTo: container.workingDirectory))?.projects ?? []
            containers = [path] + projects
        case .package:
            return nil
        }
        return containers.flatMap { ProjectFileReader.schemeFolders(in: $0) }.map { $0 + "/" + scheme + ".xcscheme" }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Whether the target a scheme tests is a UI-test bundle; nil when its project can't be read or has no such target.
    static func isUITest(_ testable: SchemeFile.Buildable, relativeTo folder: String) -> Bool? {
        guard testable.container.hasSuffix(".xcodeproj") else { return false }       // a package's test target
        guard let project = XcodeProjectFile.read(folder + "/" + testable.container),
              let target = project.targets.first(where: { $0.id == testable.id }) ?? project.targets.first(where: { $0.name == testable.name })
        else { return nil }
        return target.productType.hasPrefix(productType)
    }
}
