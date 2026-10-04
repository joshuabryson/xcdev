import Foundation
import Synchronization

/// A child process started with posix_spawn (Foundation's `Process` would put a passthrough child in a process group
/// of its own, out of the terminal's reach). xcd reaps it itself, under the lock `signal` takes, so a signal never
/// reaches a pid or process group the system may have given to another process: until it is reaped, a child's pid,
/// and so its group's id, can't be reused. What that leaves out: once a group's leader has been reaped, anything it
/// left running in the group can no longer be signalled safely, and isn't. The handler keeps leaders that exit after
/// it fires unreaped for that reason (see `watch`).
final class ChildProcess: Sendable {
    enum Stdio {
        /// xcd's own stdin, stdout, and stderr: the terminal, for a passthrough child.
        case shared
        /// stdin from `input` (or /dev/null), stdout and stderr to these descriptors.
        case redirected(output: Int32, error: Int32, input: String? = nil)
    }

    enum Life { case running, exited, reaped }

    /// How the child's stdin, stdout, and stderr are set up, in order.
    enum FileAction: Equatable {
        case inherit(Int32)
        case duplicate(Int32, to: Int32)
        case openNull(Int32, flags: Int32)
        case openFile(Int32, path: String, flags: Int32)
    }

    /// Shared: xcd's own 0, 1, and 2, except that one xcd's parent closed (`xcd hi <&-`) is /dev/null, since
    /// posix_spawn fails on inheriting a closed descriptor. Redirected: stdout and stderr are duplicated before
    /// /dev/null is opened as stdin, so a pipe or log numbered 0 (possible when xcd's stdin was closed) is copied first.
    static func fileActions(for stdio: Stdio, isOpen: (Int32) -> Bool = { fcntl($0, F_GETFD) != -1 }) -> [FileAction] {
        switch stdio {
        case .shared:
            return (0...2).map { isOpen($0) ? .inherit($0) : .openNull($0, flags: $0 == 0 ? O_RDONLY : O_WRONLY) }
        case .redirected(let output, let error, let input):
            return [.duplicate(output, to: 1), .duplicate(error, to: 2),
                    input.map { .openFile(0, path: $0, flags: O_RDONLY) } ?? .openNull(0, flags: O_RDONLY)]
        }
    }

    let pid: pid_t
    /// Whether the child leads a process group of its own (every child but a passthrough one), so `signal` reaches
    /// what it started too: the compilers under xcodebuild, a shell's background jobs. A passthrough child is in
    /// xcd's group, where the terminal's Ctrl-C reaches it, so it is signalled alone.
    let leadsGroup: Bool
    private let life = Mutex(Life.running)
    private let ended = ExitSignal()

    init(pid: pid_t, leadsGroup: Bool) {
        self.pid = pid
        self.leadsGroup = leadsGroup
    }

    /// Starts `executable` with exactly `environment`, default signal handling, no blocked signals, and no descriptors
    /// but stdin, stdout, and stderr. Throws the errno posix_spawn returns (for example ENOENT).
    static func spawn(_ executable: String, arguments: [String], environment: [String: String], workingDirectory: String?,
                      stdio: Stdio, leadsGroup: Bool, newSession: Bool = false) throws -> ChildProcess {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for action in fileActions(for: stdio) {
            switch action {
            case .inherit(let fd): posix_spawn_file_actions_addinherit_np(&actions, fd)
            case .duplicate(let fd, let target): posix_spawn_file_actions_adddup2(&actions, fd, target)
            case .openNull(let fd, let flags): posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", flags, 0)
            case .openFile(let fd, let path, let flags): posix_spawn_file_actions_addopen(&actions, fd, path, flags, 0)
            }
        }
        if let workingDirectory { posix_spawn_file_actions_addchdir_np(&actions, workingDirectory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // While a passthrough child runs xcd ignores SIGINT and SIGQUIT, and an ignored signal stays ignored across
        // exec, so every signal is reset to its default.
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        var flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        if newSession {
            // A session of its own (and so a group of its own) that no terminal can signal: for processes that must
            // outlive this xcd (`DetachedProcessLaunching`).
            flags |= POSIX_SPAWN_SETSID
        } else if leadsGroup {
            flags |= POSIX_SPAWN_SETPGROUP
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return ChildProcess(pid: pid, leadsGroup: leadsGroup)
    }

    /// Waits on a thread of its own for the child to exit, without reaping it (WNOWAIT), then reaps it unless
    /// `keepZombie()`: once xcd is interrupted, an exited child stays a zombie, which keeps its pid and group from
    /// being reused while the handler stops what is left in the group.
    func watch(keepZombie: @escaping @Sendable () -> Bool) {
        Thread.detachNewThread { [self] in
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while result == -1 && errno == EINTR
            exited(reap: !keepZombie())
            ended.finish(result == 0 ? Self.status(info) : 1)
        }
    }

    /// The exit code, or 128 + the signal that killed the child, as a shell reports it.
    static func status(_ info: siginfo_t) -> Int32 {
        info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
    }

    /// Records that the child has exited, reaping it when `reap` is set; after that it is never signalled.
    func exited(reap: Bool) {
        life.withLock { life in
            guard life == .running else { return }
            if reap {
                while waitpid(pid, nil, 0) == -1 && errno == EINTR {}
                life = .reaped
            } else {
                life = .exited
            }
        }
    }

    /// The child's status once it has exited (see `status`).
    func wait() async -> Int32 { await ended.wait() }

    /// Sends `signal` to the child's group, or to the child alone when it shares xcd's group, unless it has been
    /// reaped. Returns whether `send` succeeded; signal 0 so asks whether anything in the group is alive (macOS
    /// refuses to signal a group of zombies, so an exited leader with nothing left under it counts as gone).
    @discardableResult
    func signal(_ signal: Int32, using send: (pid_t, Int32) -> Int32 = { kill($0, $1) }) -> Bool {
        life.withLock { life in life != .reaped && send(leadsGroup ? -pid : pid, signal) == 0 }
    }

    /// Whether the child, or for a group leader anything in its group, is still running.
    func isAlive(using send: (pid_t, Int32) -> Int32 = { kill($0, $1) }) -> Bool {
        leadsGroup ? signal(0, using: send) : life.withLock { $0 == .running }
    }

    /// Sends SIGTERM, then SIGKILL two seconds later to whatever is still running. Returns whether it was running.
    @discardableResult
    func terminate() -> Bool {
        guard isAlive(), signal(SIGTERM) else { return false }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if isAlive() { signal(SIGKILL) }
        }
        return true
    }
}

final class ExitSignal: Sendable {
    private let state = Mutex<(status: Int32?, waiters: [CheckedContinuation<Int32, Never>])>((nil, []))

    func finish(_ status: Int32) {
        let waiters = state.withLock { state in
            state.status = status
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume(returning: status) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            let ready: Int32? = state.withLock { state in
                if let status = state.status { return status }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
