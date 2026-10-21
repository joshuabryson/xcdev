import Foundation

/// Whether the app that runs xcd holds the grants a Mac `ui` command needs.
public struct MacPermissionsCheck: DoctorCheck {
    public let id = "mac-permissions"
    public init() { /* stateless */ }

    public static func applies(devices: [String: DeviceSpec]) -> Bool { devices.values.contains { $0.isMac } }

    public func applies(_ env: DoctorEnvironment) -> Bool { Self.applies(devices: env.project?.config?.allDevices ?? [:]) }

    public func detect(_ env: DoctorEnvironment) -> [DoctorProblem] {
        Self.problems(MacPermissions.read(api: env.accessibility(), hostApp: env.hostApp()))
    }

    public static func problems(_ permissions: MacPermissions) -> [DoctorProblem] {
        var problems: [DoctorProblem] = []
        let app = permissions.hostApp
        if !permissions.accessibility {
            problems.append(DoctorProblem(check: "mac-permissions", message: "\(app) has no Accessibility permission, so `xcd ui` cannot read a Mac app's windows",
                                          next: MacPermissions.accessibilityNext(app)))
        }
        if !permissions.screenRecording {
            problems.append(DoctorProblem(check: "mac-permissions",
                                          message: "\(app) has no Screen Recording permission, so `xcd ui screenshot` and `record` cannot capture a Mac app's window",
                                          next: MacPermissions.screenRecordingNext(app)))
        }
        return problems
    }

    public func fix(_ problem: DoctorProblem, _ env: DoctorEnvironment) throws {
        throw XcdError(.usage, "a permission is granted in System Settings, not by xcd", next: problem.next ?? "")
    }
}
