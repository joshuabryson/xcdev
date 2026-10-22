import AppKit

/// One running copy of an app, as macOS lists it by bundle id.
public struct MacRunningCopy: Sendable, Equatable {
    public let pid: Int32
    /// The copy's executable; nil when macOS does not say.
    public let executablePath: String?

    public init(pid: Int32, executablePath: String?) {
        self.pid = pid
        self.executablePath = executablePath
    }
}

/// The running copies of an app, whoever started them.
public protocol MacRunningAppsListing: Sendable {
    func copies(of bundleId: String) -> [MacRunningCopy]
}

/// `NSRunningApplication`: every app LaunchServices knows to be running, by bundle id. The class may be used from any
/// thread, and nothing of it outlives this call.
public struct SystemRunningApps: MacRunningAppsListing {
    public init() { /* stateless */ }

    public func copies(of bundleId: String) -> [MacRunningCopy] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .map { MacRunningCopy(pid: $0.processIdentifier, executablePath: $0.executableURL?.path) }
    }
}
