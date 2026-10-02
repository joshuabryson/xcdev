import Foundation

public enum ProjectContainer: Sendable, Equatable {
    case workspace(String)
    case project(String)
    /// A Swift package: xcodebuild runs in this directory with no container flag.
    case package(directory: String)

    /// From `project:` in .xcdev.yml, relative to the worktree checkout. The file must exist.
    public static func resolve(config: XcdevConfig, worktreeRoot: String) throws -> ProjectContainer {
        let url = URL(fileURLWithPath: worktreeRoot).appendingPathComponent(config.project).standardizedFileURL
        let next = "set `project:` in .xcdev.yml to the .xcworkspace, .xcodeproj, or Package.swift, relative to the project root"
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XcdError(.configInvalid, "project: \(config.project) does not exist in \(worktreeRoot)", next: next)
        }
        switch url.pathExtension {
        case "xcworkspace": return .workspace(url.path)
        case "xcodeproj": return .project(url.path)
        default:
            guard url.lastPathComponent == "Package.swift" else {
                throw XcdError(.configInvalid, "project: \(config.project) is not a .xcworkspace, .xcodeproj, or Package.swift",
                               next: next)
            }
            return .package(directory: url.deletingLastPathComponent().path)
        }
    }

    public var arguments: [String] {
        switch self {
        case .workspace(let path): return ["-workspace", path]
        case .project(let path): return ["-project", path]
        case .package: return []
        }
    }

    public var workingDirectory: String {
        switch self {
        case .workspace(let path), .project(let path): return (path as NSString).deletingLastPathComponent
        case .package(let directory): return directory
        }
    }

    public var isPackage: Bool {
        if case .package = self { return true }
        return false
    }
}

public enum Destination: Sendable, Equatable {
    case simulator(udid: String)
    case macOS

    public var argument: String {
        switch self {
        case .simulator(let udid): return "id=\(udid)"
        case .macOS: return "platform=macOS"
        }
    }
}

/// One xcodebuild run against this worktree's DerivedData and SourcePackages.
public struct XcodebuildRequest: Sendable, Equatable {
    public enum Action: String, Sendable { case clean, build, test }

    public var actions: [Action]
    public var container: ProjectContainer
    public var scheme: String
    public var destination: Destination?
    public var configuration: String?
    public var paths: WorktreePaths
    public var resultBundle: String?
    public var onlyTesting: [String]
    public var skipTesting: [String]
    /// Where package checkouts go instead of `paths.sourcePackages` (`xcd init`'s per-project package cache).
    public var sourcePackages: String?

    public init(actions: [Action], container: ProjectContainer, scheme: String, destination: Destination? = nil,
                configuration: String? = nil, paths: WorktreePaths, resultBundle: String? = nil,
                onlyTesting: [String] = [], skipTesting: [String] = [], sourcePackages: String? = nil) {
        self.actions = actions
        self.container = container
        self.scheme = scheme
        self.destination = destination
        self.configuration = configuration
        self.paths = paths
        self.resultBundle = resultBundle
        self.onlyTesting = onlyTesting
        self.skipTesting = skipTesting
        self.sourcePackages = sourcePackages
    }

    public var arguments: [String] {
        var args = actions.map(\.rawValue) + commonArguments
        if let resultBundle { args += ["-resultBundlePath", resultBundle] }
        args += onlyTesting.map { "-only-testing:\($0)" } + skipTesting.map { "-skip-testing:\($0)" }
        if actions.contains(.build) || actions.contains(.test) {
            // Without this, xcodebuild stops after the first file with errors and hides the rest.
            args.append("-IDEBuildingContinueBuildingAfterErrors=YES")
        }
        return args
    }

    public func invocation(developerDir: String?, logFile: String, timeout: Duration) -> Invocation {
        var invocation = Invocation.xcrun(["xcodebuild"] + arguments, developerDir: developerDir, timeout: timeout)
        invocation.workingDirectory = container.workingDirectory
        invocation.outputFile = logFile
        return invocation
    }

    /// `-showBuildSettings -json` for the same scheme, destination, configuration, and paths.
    public func buildSettingsInvocation(developerDir: String?) -> Invocation {
        var invocation = Invocation.xcrun(["xcodebuild", "-showBuildSettings", "-json"] + commonArguments,
                                          developerDir: developerDir, timeout: .seconds(120))
        invocation.workingDirectory = container.workingDirectory
        return invocation
    }

    private var commonArguments: [String] {
        var args = container.arguments + ["-scheme", scheme]
        if let configuration { args += ["-configuration", configuration] }
        if let destination { args += ["-destination", destination.argument] }
        return args + ["-derivedDataPath", paths.derivedData, "-clonedSourcePackagesDirPath", sourcePackages ?? paths.sourcePackages]
    }
}
