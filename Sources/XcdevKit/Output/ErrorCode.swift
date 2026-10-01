/// xcdev's own failure categories. Diagnostics from underlying tools pass through unchanged
/// inside results and are never mapped to these codes.
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
    case xcodeMissing = "xcode_missing"
    case xcodeRuntimeMismatch = "xcode_runtime_mismatch"
    case runtimeMissing = "runtime_missing"
    case cloneFailed = "clone_failed"
    case simulatorFailed = "simulator_failed"
    case subprocessFailed = "subprocess_failed"
    case timeout
    case internalError = "internal"

    /// 1 = the task failed (fix the code), 2 = fix the invocation or config, 3 = fix the environment (`xcd doctor`).
    public var exitCode: Int32 {
        switch self {
        case .buildFailed, .testFailed, .appCrashed:
            return 1
        case .usage, .notInProject, .configMissing, .configInvalid, .deviceUnknown,
             .deviceTypeUnknown, .worktreeNotFound, .worktreeDirty, .appNotBuilt:
            return 2
        case .xcodeMissing, .xcodeRuntimeMismatch, .runtimeMissing, .cloneFailed, .simulatorFailed,
             .subprocessFailed, .timeout, .internalError:
            return 3
        }
    }
}
