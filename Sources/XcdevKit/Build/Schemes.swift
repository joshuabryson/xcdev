import Foundation

public enum SchemeRole: String, Sendable { case app, test }

public enum Schemes {
    /// `requested` is a key under `schemes:` ("app", "test") or a scheme name. Without it, the role's default:
    /// schemes.app for build and run, schemes.test (else schemes.app) for test.
    public static func configured(_ requested: String?, role: SchemeRole, config: XcdevConfig) -> String? {
        switch requested {
        case "app": return config.schemes?.app ?? "app"
        case "test": return config.schemes?.test ?? "test"
        case let name?: return name
        case nil:
            switch role {
            case .app: return config.schemes?.app
            case .test: return config.schemes?.test ?? config.schemes?.app
            }
        }
    }

    /// Scheme names from `xcodebuild -list -json` (a project, workspace, or package). Empty if unreadable.
    public static func parseList(_ data: Data) -> [String] {
        struct Container: Decodable { let schemes: [String]? }
        struct List: Decodable { let project: Container?; let workspace: Container? }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { return [] }
        return list.project?.schemes ?? list.workspace?.schemes ?? []
    }

    public static func listInvocation(_ container: ProjectContainer, paths: WorktreePaths,
                                      developerDir: String?) -> Invocation {
        // Package resolution during -list must also stay inside this worktree's state.
        var invocation = Invocation.xcrun(["xcodebuild", "-list", "-json"] + container.arguments
                                              + ["-derivedDataPath", paths.derivedData,
                                                 "-clonedSourcePackagesDirPath", paths.sourcePackages],
                                          developerDir: developerDir, timeout: .seconds(120))
        invocation.workingDirectory = container.workingDirectory
        return invocation
    }

    public static func missing(role: SchemeRole, available: [String]) -> XcdError {
        XcdError(.usage, "no \(role.rawValue) scheme is configured",
                 next: available.isEmpty
                     ? "set schemes.\(role.rawValue) in .xcdev.yml (or pass --scheme); `xcodebuild -list` shows the schemes"
                     : "set schemes.\(role.rawValue) in .xcdev.yml to one of: \(available.joined(separator: ", ")) (or pass --scheme)")
    }
}
