import Foundation
import Synchronization
import XcdevKit

/// Signatures by bundle path, as the Security framework would read them. A path never set reads as unsigned; a path
/// in `failing` throws, as an unreadable signature does.
public final class FakeBundleReader: MacBundleReading, Sendable {
    struct State {
        var infos: [String: MacSigningInfo] = [:]
        var failing: Set<String> = []
        var calls: [String] = []
    }
    let state = Mutex(State())

    public init() { /* every path starts unsigned */ }

    /// What a read of `path` answers; nil makes the bundle unsigned.
    public func set(_ info: MacSigningInfo?, for path: String) { state.withLock { $0.infos[path] = info } }
    public var failing: Set<String> {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }
    /// The paths read, in order.
    public var calls: [String] { state.withLock { $0.calls } }

    public func signingInfo(of appPath: String) throws -> MacSigningInfo? {
        try state.withLock { state in
            state.calls.append(appPath)
            guard !state.failing.contains(appPath) else {
                throw XcdError(.internalError, "cannot read the signature of \(appPath): OSStatus -67028")
            }
            return state.infos[appPath]
        }
    }
}
