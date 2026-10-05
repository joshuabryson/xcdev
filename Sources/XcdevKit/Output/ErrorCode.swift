import Foundation

/// xcdev's own failure categories. Diagnostics from underlying tools pass through unchanged
/// inside results and are never mapped to these codes. A code never changes meaning once released.
public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case usage
    case notInProject = "not_in_project"
    case configMissing = "config_missing"
    case configInvalid = "config_invalid"
    case deviceUnknown = "device_unknown"
    case deviceTypeUnknown = "device_type_unknown"
    case worktreeNotFound = "worktree_not_found"
    case worktreeDirty = "worktree_dirty"
    case appNotBuilt = "app_not_built"
    case buildFailed = "build_failed"
    case testFailed = "test_failed"
    case appCrashed = "app_crashed"
    case elementNotFound = "element_not_found"
    case elementNotHittable = "element_not_hittable"
    case waitTimeout = "wait_timeout"
    case elementAmbiguous = "element_ambiguous"
    case staleRef = "stale_ref"
    case platformUnsupported = "platform_unsupported"
    case runnerFailed = "runner_failed"
    case hookFailed = "hook_failed"
    case xcodeMissing = "xcode_missing"
    case xcodeRuntimeMismatch = "xcode_runtime_mismatch"
    case runtimeMissing = "runtime_missing"
    case cloneFailed = "clone_failed"
    case simulatorFailed = "simulator_failed"
    case subprocessFailed = "subprocess_failed"
    case timeout
    case doctorProblems = "doctor_problems"
    case internalError = "internal"

    /// 1 = the task failed (fix the code), 2 = fix the invocation or config, 3 = fix the environment (`xcd doctor`).
    public var exitCode: Int32 {
        switch self {
        case .buildFailed, .testFailed, .appCrashed, .elementNotFound, .elementNotHittable, .waitTimeout, .hookFailed:
            return 1
        case .usage, .notInProject, .configMissing, .configInvalid, .deviceUnknown,
             .deviceTypeUnknown, .worktreeNotFound, .worktreeDirty, .appNotBuilt, .elementAmbiguous, .staleRef, .platformUnsupported:
            return 2
        case .xcodeMissing, .xcodeRuntimeMismatch, .runtimeMissing, .cloneFailed, .simulatorFailed,
             .subprocessFailed, .timeout, .doctorProblems, .internalError, .runnerFailed:
            return 3
        }
    }

    /// What the code means, for `xcd help errors`. The switch is exhaustive, so a new code can't ship undocumented.
    public var summary: String {
        switch self {
        case .usage: return "The command line is wrong: an unknown flag, a bad value, or a missing argument."
        case .notInProject: return "The current directory isn't inside a git repository (or has no Xcode project for init)."
        case .configMissing: return "The project has no .xcdev.yml; run `xcd guide setup`."
        case .configInvalid: return ".xcdev.yml (or .xcdev.local.yml, or an init answer) has an unknown key or a bad value."
        case .deviceUnknown: return "--device names a device that isn't under devices: in .xcdev.yml."
        case .deviceTypeUnknown: return "A device's type isn't a simulator device type installed with this Xcode."
        case .worktreeNotFound: return "No worktree with that name, or its checkout was deleted outside xcd."
        case .worktreeDirty: return "The worktree has uncommitted changes, so it wasn't removed."
        case .appNotBuilt: return "The command needs a build (or launch) that hasn't happened in this worktree yet."
        case .buildFailed: return "xcodebuild reported build errors; they are listed in compiler format."
        case .testFailed: return "Tests failed, or no tests ran."
        case .appCrashed: return "The app crashed or exited during the crash window after launch."
        case .elementNotFound: return "No element on screen matched the target within the timeout."
        case .elementNotHittable: return "The element exists but is off screen or disabled, so it wasn't acted on."
        case .waitTimeout: return "`xcd ui wait` gave up: the element didn't appear (or, with --gone, didn't go away)."
        case .elementAmbiguous: return "More than one element matched the target; the error lists them with refs."
        case .staleRef: return "A ref from an earlier `xcd ui tree` no longer names one element; read the tree again."
        case .platformUnsupported: return "UI driving works on iPhone and iPad simulators only."
        case .runnerFailed: return "The UI runner inside the simulator could not be built or started, or stopped answering."
        case .hookFailed: return "A hook from .xcdev.yml exited non-zero; the error names the hook and its log."
        case .xcodeMissing: return "The Xcode that .xcdev.yml or --xcode asks for isn't installed."
        case .xcodeRuntimeMismatch: return "A simulator runtime is newer than the selected Xcode supports."
        case .runtimeMissing: return "No installed simulator runtime matches the device's runtime setting."
        case .cloneFailed: return "simctl could not create, clone, or pair a simulator."
        case .simulatorFailed: return "A simctl command failed (boot, install, launch, …)."
        case .subprocessFailed: return "An external tool failed in a way xcd doesn't recognize; details carry its command, exit code, and stderr."
        case .timeout: return "An external command ran past its deadline and was stopped."
        case .doctorProblems: return "`xcd doctor` or `xcd prune` found problems that remain; each one says how to fix it."
        case .internalError: return "A bug in xcd, or a corrupt state file."
        }
    }
}

/// `xcd help errors`: every error code with its exit code and meaning.
public struct ErrorsReport: Reportable {
    public struct Row: Codable, Sendable, Equatable {
        public let code: String
        public let exitCode: Int32
        public let summary: String
    }

    public let errors: [Row]

    public init() {
        errors = ErrorCode.allCases.map { Row(code: $0.rawValue, exitCode: $0.exitCode, summary: $0.summary) }
    }

    public var text: String {
        let width = (errors.map(\.code.count).max() ?? 0) + 2
        var lines = ["exit codes: 1 = the task failed (fix the code), 2 = fix the command line or config, 3 = fix the environment (`xcd doctor`)"]
        lines += errors.map { $0.code.padding(toLength: width, withPad: " ", startingAt: 0) + "\($0.exitCode)  " + $0.summary }
        lines.append("every failure ends with `next:` (JSON: error.next) saying what to do")
        return lines.joined(separator: "\n")
    }
}
