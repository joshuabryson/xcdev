import Synchronization

/// Notes that are not one command's own, added while it runs: a config borrowed from the
/// main checkout, a hook that waits. Each is kept once, in the order added.
public final class Notes: Sendable {
    /// The notes of the command being run, which its result or failure is printed with.
    @TaskLocal public static var current: Notes?

    private let lines = Mutex<[String]>([])

    public func add(_ note: String) {
        lines.withLock { if !$0.contains(note) { $0.append(note) } }
    }

    public var all: [String] { lines.withLock { $0 } }
}
