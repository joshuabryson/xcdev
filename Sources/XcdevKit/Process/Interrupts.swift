import Foundation
import Synchronization

/// What SIGINT, SIGTERM, and SIGHUP do to xcd: one handler for the whole process, installed when the CLI starts.
///
/// Every child but a passthrough one leads a process group of its own, which the terminal's Ctrl-C doesn't reach,
/// so the handler stops them: SIGINT to each child's group (xcodebuild treats it as a clean cancel), SIGTERM to what
/// is still running after `grace`, and SIGKILL a second after that. Then it runs the cleanups registered with
/// `addCleanup` (newest first; those that only touch files, like `init`'s scratch folder, before those that write
/// to stderr, like a spinner's line), prints one line on stderr (dropped if stderr is gone), and exits with
/// 128 + the signal: 130 for SIGINT, 143 for SIGTERM, 129 for SIGHUP. From the moment it fires no new write starts
/// (`perform`, `output`) and no new child starts. A write already under way gets a second to finish; one that is
/// stuck (stdout is a pipe nobody reads) doesn't hold the handler up, and xcd then exits without flushing.
///
/// A passthrough child (a project command or plugin) is in xcd's own process group instead, so it reads the terminal
/// and gets the terminal's Ctrl-C itself, as under a shell. While one runs, xcd ignores SIGINT and SIGQUIT, passes
/// SIGTERM on to it, and then returns the child's status (128 + the signal if a signal ended it).
public final class Interrupts: Sendable {
    /// The CLI's: `SystemProcessRunner` and `Services` use it unless given another (tests make their own).
    public static let shared = Interrupts()

    public struct Cleanup: Sendable, Hashable {
        let id: Int
    }

    private struct State {
        var children: [(child: ChildProcess, name: String)] = []
        var foreground: [ChildProcess] = []
        var cleanups: [(id: Int, writes: Bool, run: @Sendable () -> Void)] = []
        var nextID = 0
        var fired = false
        /// Writes `perform` is running now. They run outside the lock, so a stuck one can't block the handler.
        var writing = 0
    }

    private let state = Mutex(State())
    private let installations = Mutex<[Installation]>([])
    /// Where the signal sources deliver, so a passthrough child's end can wait for a Ctrl-C that came with it.
    private let queue = DispatchQueue(label: "xcd.interrupts")
    let grace: Duration
    let report: @Sendable (String) -> Void
    let send: @Sendable (pid_t, Int32) -> Int32
    let sleep: @Sendable (Duration) -> Void

    /// `report` prints the handler's line (stderr, as `xcd: <line>`); `send` and `sleep` are `kill` and a real sleep.
    public init(grace: Duration = .seconds(3),
                report: @escaping @Sendable (String) -> Void = { StandardError.write("xcd: \($0)\n") },
                send: @escaping @Sendable (pid_t, Int32) -> Int32 = { kill($0, $1) },
                sleep: @escaping @Sendable (Duration) -> Void = { usleep(UInt32($0 / .microseconds(1))) }) {
        self.grace = grace
        self.report = report
        self.send = send
        self.sleep = sleep
    }

    /// Whether SIGINT or SIGTERM has started the handler.
    public var fired: Bool { state.withLock { $0.fired } }

    // MARK: Signals

    /// What `install` set up, kept here: a dispatch source with no owner is released, and then never fires.
    private struct Installation: @unchecked Sendable {
        let sources: [any DispatchSourceSignal]
        let previous: [(signal: Int32, action: sigaction)]
    }

    /// Makes SIGINT, SIGTERM, and SIGHUP run `handle`, then `exit` with its code (by default `exitPromptly`). The
    /// signals are ignored by the process and delivered to dispatch sources instead, so the handler runs as ordinary
    /// code on a queue. A signal xcd started with ignored is left alone, as other tools leave it: SIGHUP under
    /// `nohup`, SIGINT in a shell script's background job (`xcd build &`).
    public func install(exit: @escaping @Sendable (Int32) -> Void = Interrupts.exitPromptly) {
        var sources: [any DispatchSourceSignal] = []
        var previous: [(signal: Int32, action: sigaction)] = []
        for signal in [SIGINT, SIGTERM, SIGHUP] {
            var ignore = sigaction()
            var old = sigaction()
            sigaction(signal, nil, &old)
            if unsafeBitCast(old.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) { continue }
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            sigaction(signal, &ignore, nil)
            previous.append((signal, old))
            let source = DispatchSource.makeSignalSource(signal: signal, queue: queue)
            source.setEventHandler { [self] in
                if let code = handle(signal) { exit(code) }
            }
            source.resume()
            sources.append(source)
        }
        installations.withLock { $0.append(Installation(sources: sources, previous: previous)) }
    }

    /// Whether `install` set up a source for `signal`.
    func handles(_ signal: Int32) -> Bool {
        installations.withLock { $0.contains { $0.previous.contains { $0.signal == signal } } }
    }

    /// Undoes `install` (for tests: the CLI keeps the handler until it exits). Cancelling the sources releases their
    /// closures, which hold this instance.
    func uninstall() {
        for installation in installations.withLock({ list in defer { list = [] }; return list }).reversed() {
            installation.sources.forEach { $0.cancel() }
            for (signal, action) in installation.previous {
                var restore = action
                sigaction(signal, &restore, nil)
            }
        }
    }

    /// What a signal does; returns the code to exit with, or nil to carry on (a passthrough child is running, or the
    /// handler has already fired).
    func handle(_ signal: Int32) -> Int32? {
        enum Action {
            case ignore
            case forward([ChildProcess])
            case stop([(child: ChildProcess, name: String)], cleanups: [(writes: Bool, run: @Sendable () -> Void)])
        }
        let action: Action = state.withLock { state in
            if !state.foreground.isEmpty {
                return signal == SIGINT ? .ignore : .forward(state.foreground)   // Ctrl-C reached the child already
            }
            guard !state.fired else { return .ignore }
            state.fired = true
            return .stop(state.children, cleanups: state.cleanups.reversed().map { ($0.writes, $0.run) })
        }
        switch action {
        case .ignore:
            return nil
        case .forward(let children):
            for child in children { child.signal(signal, using: send) }
            return nil
        case .stop(let children, let cleanups):
            waitForWrites()
            let stopped = stop(children)
            // Each on its own and bounded, so a stuck one can't skip the rest: first those that only touch files
            // (init's scratch folder), then those that write to stderr (a spinner's line), which may be stuck too,
            // like the report.
            for cleanup in cleanups where !cleanup.writes { _ = Self.bounded(.seconds(5), cleanup.run) }
            for cleanup in cleanups where cleanup.writes { _ = Self.bounded(.seconds(1), cleanup.run) }
            let report = report
            _ = Self.bounded(.seconds(1)) {
                report("interrupted" + (stopped.isEmpty ? "" : "; stopped " + stopped.joined(separator: ", ")))
            }
            return 128 + signal
        }
    }

    /// Gives writes already under way up to a second to finish, so a result being printed isn't cut short.
    private func waitForWrites() {
        let step = Duration.milliseconds(50)
        var waited = Duration.zero
        while state.withLock({ $0.writing }) > 0, waited < .seconds(1) {
            sleep(step)
            waited += step
        }
    }

    /// Runs `work` on a thread of its own and waits for it up to `limit`. Returns whether it finished.
    static func bounded(_ limit: DispatchTimeInterval, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + limit) == .success
    }

    /// Flushes stdout and stderr if that finishes within a second, then ends the process at once. Not `exit`: its
    /// flush would wait forever on a pipe nobody reads, and xcd has nothing else to run at exit.
    public static func exitPromptly(_ code: Int32) {
        _ = bounded(.seconds(1)) { fflush(nil) }
        _exit(code)
    }

    /// SIGINT to each child's group, SIGTERM to those still running after `grace`, SIGKILL to those still running a
    /// second later. Returns the names of the children it signalled.
    private func stop(_ children: [(child: ChildProcess, name: String)]) -> [String] {
        var running = children.filter { $0.child.signal(SIGINT, using: send) }
        var names: [String] = []
        for name in running.map(\.name) where !names.contains(name) { names.append(name) }
        running = waitWhileAlive(running, upTo: grace)
        running = running.filter { $0.child.signal(SIGTERM, using: send) }
        running = waitWhileAlive(running, upTo: .seconds(1))
        running = running.filter { $0.child.signal(SIGKILL, using: send) }
        _ = waitWhileAlive(running, upTo: .seconds(1))
        return names
    }

    /// The children with something still running in their group after up to `limit`, checked every 50 ms.
    private func waitWhileAlive(_ children: [(child: ChildProcess, name: String)],
                                upTo limit: Duration) -> [(child: ChildProcess, name: String)] {
        let step = Duration.milliseconds(50)
        var waited = Duration.zero
        var alive = children.filter { $0.child.isAlive(using: send) }
        while !alive.isEmpty, waited < limit {
            sleep(step)
            waited += step
            alive = alive.filter { $0.child.isAlive(using: send) }
        }
        return alive
    }

    // MARK: Children

    /// Starts a child with `spawn` and tracks it until `finished`. A passthrough child (`foreground`) owns Ctrl-C
    /// while it runs: SIGINT and SIGQUIT are ignored by xcd from just before it starts. Throws instead of starting
    /// anything once the handler has fired. Holding the lock while spawning means the handler sees every child.
    func launch(_ argv: [String], foreground: Bool, _ spawn: () throws -> ChildProcess) throws -> ChildProcess {
        try state.withLock { state in
            guard !state.fired else {
                throw XcdError(.subprocessFailed, "xcd was interrupted, so `\(argv.prefix(3).joined(separator: " "))` was not started")
            }
            if foreground { TerminalSignals.ignore() }
            do {
                let child = try spawn()
                if foreground {
                    state.foreground.append(child)
                } else {
                    state.children.append((child, Self.name(argv)))
                }
                return child
            } catch {
                if foreground { TerminalSignals.restore() }
                throw error
            }
        }
    }

    /// Stops tracking `child`, which has exited. After the last passthrough child, SIGINT and SIGQUIT are handled
    /// as before the first one started.
    func finished(_ child: ChildProcess) {
        let isForeground = state.withLock { $0.foreground.contains { $0 === child } }
        // A Ctrl-C that ended the child reached xcd too; let the handler see it while the child still counts.
        if isForeground { queue.sync {} }
        state.withLock { state in
            state.children.removeAll { $0.child === child }
            guard isForeground else { return }
            state.foreground.removeAll { $0 === child }
            TerminalSignals.restore()
        }
    }

    /// The name the handler's line gives a child: the tool, not xcrun.
    static func name(_ argv: [String]) -> String {
        argv.first == "xcrun" && argv.count > 1 ? argv[1] : argv.first ?? "?"
    }

    // MARK: Cleanups and output

    /// Runs `cleanup` if the handler fires before `removeCleanup`. `writes`: it writes to stderr, so it runs after
    /// the cleanups that don't, and gets less time (a closed terminal or a full pipe can stall it).
    public func addCleanup(writes: Bool = false, _ cleanup: @escaping @Sendable () -> Void) -> Cleanup {
        state.withLock { state in
            state.nextID += 1
            state.cleanups.append((state.nextID, writes, cleanup))
            return Cleanup(id: state.nextID)
        }
    }

    public func removeCleanup(_ cleanup: Cleanup) {
        state.withLock { $0.cleanups.removeAll { $0.id == cleanup.id } }
    }

    /// Runs `write` unless the handler has fired, and returns whether it ran. The write runs outside the lock (it may
    /// block on a full pipe); the handler waits for it up to a second, so in practice a write is whole and before
    /// the interrupt, or never.
    @discardableResult
    public func perform(_ write: () -> Void) -> Bool {
        let started = state.withLock { state in
            guard !state.fired else { return false }
            state.writing += 1
            return true
        }
        guard started else { return false }
        defer { state.withLock { $0.writing -= 1 } }
        write()
        return true
    }

    /// Like `perform`, but once the handler has fired it doesn't return (until cancelled): the handler is stopping
    /// the children and will exit, and the caller's result, ended early by the interrupt, must not be printed.
    public func output(_ write: () -> Void) async {
        guard !perform(write) else { return }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(1)) }
    }
}

/// SIGINT and SIGQUIT ignored while any passthrough child runs, as a shell ignores them while a foreground job does.
/// Dispositions belong to the whole process, so the count is too: the first `ignore` saves them, the last `restore`
/// puts them back.
private enum TerminalSignals {
    private struct Saved: @unchecked Sendable {
        var users = 0
        var interrupt = sigaction()
        var quit = sigaction()
    }

    private static let saved = Mutex(Saved())

    static func ignore() {
        saved.withLock { saved in
            saved.users += 1
            guard saved.users == 1 else { return }
            var ignore = sigaction()
            ignore.__sigaction_u.__sa_handler = SIG_IGN
            sigaction(SIGINT, &ignore, &saved.interrupt)
            sigaction(SIGQUIT, &ignore, &saved.quit)
        }
    }

    static func restore() {
        saved.withLock { saved in
            saved.users -= 1
            guard saved.users == 0 else { return }
            sigaction(SIGINT, &saved.interrupt, nil)
            sigaction(SIGQUIT, &saved.quit, nil)
        }
    }
}
