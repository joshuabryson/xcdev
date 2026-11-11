import Foundation
import Testing
import XcdevTestSupport

/// The tests that wait out xcd's real interrupt timings, seconds each, run before a release with the integration
/// tests; `InterruptsTests` takes the same steps with a fake clock on every run.
private let realTimings = ProcessInfo.processInfo.environment["XCD_INTEGRATION"] == "1"

/// Runs the built `xcd` on a pseudo-terminal, as a shell would on a real one, to check what the terminal reaches:
/// a plugin reading its input, and Ctrl-C. Only processes these tests start are signalled. Running the real binary
/// keeps every signal out of the test process.
@Suite struct TerminalTests {
    /// `xcd` from this build, in the products folder that holds the test bundle.
    static func xcd() throws -> String {
        var folder = Bundle.module.bundleURL
        while folder.path != "/" {
            folder.deleteLastPathComponent()
            let candidate = folder.appendingPathComponent("xcd").path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate
            }
        }
        throw POSIXError(.ENOENT, userInfo: [NSLocalizedDescriptionKey: "no xcd beside \(Bundle.module.bundlePath)"])
    }

    /// A folder (not a project) with `xcd-<name>` plugins in `bin/`.
    static func plugins(_ scripts: [String: String]) throws -> String {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-tty-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/home", withIntermediateDirectories: true)
        for (name, script) in scripts {
            FileManager.default.createFile(atPath: base + "/bin/xcd-" + name, contents: Data(("#!/bin/sh\n" + script).utf8),
                                           attributes: [.posixPermissions: 0o755])
        }
        return base
    }

    @Test func aPluginReadsWhatIsTypedAtTheTerminal() async throws {
        let base = try Self.plugins(["asker": #"printf "pid:$$ name? "; read x; echo "got:$x""#])
        defer { try? FileManager.default.removeItem(atPath: base) }
        let session = try PseudoTerminal.spawn(Self.xcd(), ["asker"], directory: base, environment: [
            "PATH": base + "/bin:/usr/bin:/bin", "XCDEV_HOME": base + "/home", "TERM": "xterm"])
        defer { session.stop() }
        #expect(session.read(until: "name? "))
        _ = session.pluginPid(marker: base)
        session.write("bob\n")
        #expect(session.read(until: "got:bob"))
        #expect(session.waitForExit() == .exited(0))
    }

    /// Ctrl-C reaches the plugin, which owns the terminal while it runs; xcd outlives it and exits 130 (128 + SIGINT).
    @Test func ctrlCStopsAPluginAndXcdExits130() async throws {
        let nap = "3599.\(Int.random(in: 10000...99999))"                        // marks this test's sleep; only Ctrl-C ends it
        let base = try Self.plugins(["waiter": "echo \"pid:$$ ready\"; exec sleep \(nap)"])
        defer { try? FileManager.default.removeItem(atPath: base) }
        let session = try PseudoTerminal.spawn(Self.xcd(), ["waiter"], directory: base, environment: [
            "PATH": base + "/bin:/usr/bin:/bin", "XCDEV_HOME": base + "/home", "TERM": "xterm"])
        defer { session.stop() }
        #expect(session.read(until: "ready"))
        let pid = try #require(session.pluginPid(marker: nap))
        session.write("\u{03}")
        #expect(session.waitForExit() == .exited(130))
        #expect(kill(pid, 0) != 0)                                             // the plugin's sleep is gone too
    }

    /// A throwaway repo whose post-worktree-create hook (a 30-minute deadline; `wt create` clones no simulator)
    /// records its shell's pid and starts a background `sleep <nap>`, which ignores SIGINT as non-interactive shells
    /// make background jobs do. `pids` waits for both pids. The sleep lasts an hour, so only the test's signal ends
    /// the hook, however long a busy machine keeps the test waiting for its turn.
    struct HookProject {
        let project: TempProject
        let nap = "3599.\(Int.random(in: 10000...99999))"                   // in the hook's argv and the sleep's

        init() throws {
            project = try TempProject.make(config: """
                version: 1
                project: App.xcodeproj
                hooks:
                  post-worktree-create: 'echo $$ > "$XCD_PROJECT_ROOT/../sh.pid"; sleep \(nap) & echo $! > "$XCD_PROJECT_ROOT/../sleep.pid"; wait'
                """)
        }

        func pid(_ name: String) -> pid_t? {
            (try? String(contentsOfFile: project.base + "/" + name, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        /// The hook shell's and the sleep's pids, once both are running; `session` will kill them if a test fails.
        func pids(tracking session: PseudoTerminal) async throws -> (shell: pid_t, sleeper: pid_t) {
            let deadline = ContinuousClock.now + .seconds(60)
            while pid("sleep.pid") == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let shell = try #require(pid("sh.pid"))
            let sleeper = try #require(pid("sleep.pid"))
            session.track(shell, marker: nap)
            session.track(sleeper, marker: nap)
            return (shell, sleeper)
        }

        func session() throws -> PseudoTerminal {
            try PseudoTerminal.spawn(TerminalTests.xcd(), ["wt", "create", "feat"], directory: project.root, environment: [
                "PATH": "/usr/bin:/bin", "XCDEV_HOME": project.home, "TERM": "xterm"])
        }
    }

    static func waitUntilGone(_ pids: pid_t...) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while pids.contains(where: { kill($0, 0) == 0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Ctrl-C while xcd runs a child in a group of its own: the handler stops the child's whole group, including
    /// the background job that ignores SIGINT, and xcd exits 130.
    @Test(.enabled(if: realTimings, "set XCD_INTEGRATION=1 to run (waits out xcd's 3 s between SIGINT and SIGTERM)"))
    func ctrlCStopsAChildInItsOwnGroupAndItsGrandchild() async throws {
        let hook = try HookProject()
        defer { hook.project.remove() }
        let session = try hook.session()
        defer { session.stop() }
        let (shell, sleeper) = try await hook.pids(tracking: session)
        session.write("\u{03}")
        #expect(session.waitForExit() == .exited(130))
        #expect(session.read(until: "xcd: interrupted; stopped sh"))
        try await Self.waitUntilGone(shell, sleeper)
        #expect(kill(sleeper, 0) != 0 && kill(shell, 0) != 0)
    }

    /// Closing the terminal (SIGHUP, then every write to it failing) stops the hook too, and xcd exits 129 rather
    /// than crashing on the failed writes.
    @Test(.enabled(if: realTimings, "set XCD_INTEGRATION=1 to run (waits out xcd's 3 s between SIGINT and SIGTERM)"))
    func closingTheTerminalStopsTheChildrenAndExits129() async throws {
        let hook = try HookProject()
        defer { hook.project.remove() }
        let session = try hook.session()
        defer { session.stop() }
        let (shell, sleeper) = try await hook.pids(tracking: session)
        session.hangUp()
        #expect(session.waitForExit() == .exited(129))
        try await Self.waitUntilGone(shell, sleeper)
        #expect(kill(sleeper, 0) != 0 && kill(shell, 0) != 0)
    }

    /// The handler's line goes to stderr; with stderr closed it is dropped, not a crash. stdout is a pipe nobody
    /// reads, so xcd is stuck writing bare `xcd`'s plugin list when SIGHUP arrives.
    @Test(.enabled(if: realTimings, "set XCD_INTEGRATION=1 to run (waits out xcd's 1 s limits on a stuck write)"))
    func anInterruptWithStderrClosedExitsCleanly() async throws {
        let base = try Self.plugins(Dictionary(uniqueKeysWithValues: (1...600).map {
            ("plugin-with-a-long-name-so-the-list-fills-the-pipe-\($0)", "")
        }))
        defer { try? FileManager.default.removeItem(atPath: base) }
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        defer { close(fds[0]) }
        let xcd = try Spawned.start(Self.xcd(), [], directory: base, environment: [
            "PATH": base + "/bin:/usr/bin:/bin", "XCDEV_HOME": base + "/home"], stdout: fds[1], stderr: nil)
        close(fds[1])
        defer { xcd.stop() }
        func buffered() -> Int {                                             // macOS: a pipe's size is what it holds
            var info = stat()
            return fstat(fds[0], &info) == 0 ? Int(info.st_size) : 0
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while buffered() < 8192, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(buffered() >= 8192)
        try await Task.sleep(for: .milliseconds(300))                          // stuck writing the rest by now
        kill(xcd.pid, SIGHUP)
        #expect(xcd.waitForExit() == .exited(129))
    }

    /// A reader that went away (`xcd guide setup | head -0`) gives xcd EPIPE, not a SIGPIPE that kills it.
    @Test func aClosedOutputPipeDoesntKillXcd() async throws {
        let base = try Self.plugins([:])
        defer { try? FileManager.default.removeItem(atPath: base) }
        var fds: [Int32] = [0, 0]
        try #require(pipe(&fds) == 0)
        close(fds[0])
        let xcd = try Spawned.start(Self.xcd(), ["guide", "setup"], directory: base, environment: [
            "PATH": "/usr/bin:/bin", "XCDEV_HOME": base + "/home"], stdout: fds[1], stderr: fds[1])
        close(fds[1])
        defer { xcd.stop() }
        #expect(xcd.waitForExit() == .exited(0))
    }

    /// A plugin still runs when xcd's parent closed its stdin: the plugin gets /dev/null there instead.
    @Test func aPluginRunsWhenXcdsStdinIsClosed() async throws {
        let base = try Self.plugins(["hi": "echo hi-ran"])
        defer { try? FileManager.default.removeItem(atPath: base) }
        let session = try PseudoTerminal.spawn(Self.xcd(), ["hi"], directory: base, environment: [
            "PATH": base + "/bin:/usr/bin:/bin", "XCDEV_HOME": base + "/home", "TERM": "xterm"], closingStdin: true)
        defer { session.stop() }
        #expect(session.read(until: "hi-ran"))
        #expect(session.waitForExit() == .exited(0))
    }
}

/// A process on its own pseudo-terminal: a new session whose controlling terminal is the pty, so it is in the
/// foreground there and \u{03} sends SIGINT to its process group.
final class PseudoTerminal: @unchecked Sendable {
    enum Exit: Equatable { case exited(Int32), signalled(Int32) }

    let pid: pid_t
    private let master: Int32
    /// Set by `hangUp`: the descriptor is closed, and its number may already belong to something else.
    private var hungUp = false
    private(set) var output = ""
    private var exit: Exit?
    /// Processes outside the session's group that `stop` kills too: a plugin xcd put in a group of its own.
    private var others: [(pid: pid_t, marker: String)] = []

    private init(pid: pid_t, master: Int32) {
        self.pid = pid
        self.master = master
    }

    /// `closingStdin` starts the process with its stdin closed, as `<&-` in a shell does.
    static func spawn(_ executable: String, _ arguments: [String], directory: String,
                      environment: [String: String], closingStdin: Bool = false) throws -> PseudoTerminal {
        var master: Int32 = 0, slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw POSIXError(.ENXIO) }
        let name = String(cString: ptsname(master))
        close(slave)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Default signal handling and no blocked signals, as a shell starts a command (the test runner may ignore SIGINT).
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                     | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // Through sh, which takes the pty as its controlling terminal (posix_spawn's open alone doesn't), then execs.
        let script = closingStdin ? #"exec "$0" "$@" <&-"# : #"exec "$0" "$@""#
        let argv = (["/bin/sh", "-c", script, executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
        guard result == 0 else {
            close(master)
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        return PseudoTerminal(pid: pid, master: master)
    }

    /// Reads until the output contains `text`; false after `timeout` (generous: the machine may be busy).
    func read(until text: String, timeout: Duration = .seconds(30)) -> Bool {
        guard !hungUp else { return output.contains(text) }
        let deadline = ContinuousClock.now + timeout
        while !output.contains(text), ContinuousClock.now < deadline {
            var poller = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(master, &buffer, buffer.count)
            if count <= 0 { break }
            output += String(decoding: buffer[0..<count], as: UTF8.self)
        }
        return output.contains(text)
    }

    /// The pid a plugin printed as `pid:<n>`. `stop` kills it if it is still running and its command line still
    /// contains `marker` (so never a process that reused the pid).
    func pluginPid(marker: String) -> pid_t? {
        guard let pid = output.split(separator: "pid:").last.flatMap({ pid_t($0.prefix { $0.isNumber }) }) else { return nil }
        others.append((pid, marker))
        return pid
    }

    /// Has `stop` kill `pid` if it is still running with `marker` in its command line.
    func track(_ pid: pid_t, marker: String) {
        others.append((pid, marker))
    }

    static func commandLine(of pid: pid_t) -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Closes the terminal, as closing a terminal window does: the session gets SIGHUP and its writes fail.
    func hangUp() {
        guard !hungUp else { return }
        hungUp = true
        close(master)
    }

    func write(_ text: String) {
        guard !hungUp else { return }
        _ = text.utf8CString.withUnsafeBufferPointer { Darwin.write(master, $0.baseAddress, $0.count - 1) }
    }

    /// How the process ended, or nil if it is still running after `timeout`.
    func waitForExit(timeout: Duration = .seconds(30)) -> Exit? {
        let deadline = ContinuousClock.now + timeout
        while exit == nil, ContinuousClock.now < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                exit = status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .signalled(status & 0x7f)
            } else {
                _ = read(until: "\u{0}", timeout: .milliseconds(100))           // keep the pty drained
            }
        }
        return exit
    }

    /// Kills the session's process group if it is still running (only this test's processes are in it), and
    /// closes the terminal.
    func stop() {
        for other in others where Self.commandLine(of: other.pid).contains(other.marker) { kill(other.pid, SIGKILL) }
        if exit == nil {
            kill(-pid, SIGKILL)
            _ = waitForExit(timeout: .seconds(5))
        }
        hangUp()
    }
}

/// A process with no terminal, started with default signal handling, stdin from /dev/null, and stdout and stderr
/// on the given descriptors (nil: closed).
final class Spawned: @unchecked Sendable {
    let pid: pid_t
    private var exit: PseudoTerminal.Exit?

    private init(pid: pid_t) { self.pid = pid }

    static func start(_ executable: String, _ arguments: [String], directory: String, environment: [String: String],
                      stdout: Int32?, stderr: Int32?) throws -> Spawned {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdout { posix_spawn_file_actions_adddup2(&actions, stdout, 1) }
        if let stderr { posix_spawn_file_actions_adddup2(&actions, stderr, 2) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return Spawned(pid: pid)
    }

    func waitForExit(timeout: Duration = .seconds(30)) -> PseudoTerminal.Exit? {
        let deadline = ContinuousClock.now + timeout
        while exit == nil, ContinuousClock.now < deadline {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                exit = status & 0x7f == 0 ? .exited((status >> 8) & 0xff) : .signalled(status & 0x7f)
            } else {
                usleep(20_000)
            }
        }
        return exit
    }

    /// Kills the process if it is still running: it is this test's unreaped child, so its pid is still its own.
    func stop() {
        guard exit == nil else { return }
        kill(pid, SIGKILL)
        _ = waitForExit(timeout: .seconds(5))
    }
}
