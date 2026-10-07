import Synchronization

/// A value several closures share and change: the pids a fake `ps` lists, or the progress lines a command printed.
public final class Shared<Value: Sendable>: Sendable {
    private let stored: Mutex<Value>

    public init(_ value: Value) { stored = Mutex(value) }

    public var value: Value { stored.withLock { $0 } }
    public func set(_ value: Value) { stored.withLock { $0 = value } }
    public func change(_ body: (inout sending Value) -> Void) { stored.withLock { body(&$0) } }
}
