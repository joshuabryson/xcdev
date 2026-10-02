import Foundation
import Testing

/// Runs the built `xcd` on a pseudo-terminal, as a shell would on a real one, to check what the terminal reaches:
/// a plugin reading its input, and Ctrl-C. Only processes these tests start are signalled.
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
        let nap = "29.\(Int.random(in: 10000...99999))"                          // marks this test's sleep
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
}

/// A process on its own pseudo-terminal: a new session whose controlling terminal is the pty, so it is in the
/// foreground there and \u{03} sends SIGINT to its process group.
final class PseudoTerminal: @unchecked Sendable {
    enum Exit: Equatable { case exited(Int32), signalled(Int32) }

    let pid: pid_t
    private let master: Int32
    private(set) var output = ""
    private var exit: Exit?
    /// Processes outside the session's group that `stop` kills too: a plugin xcd put in a group of its own.
    private var others: [(pid: pid_t, marker: String)] = []

    private init(pid: pid_t, master: Int32) {
        self.pid = pid
        self.master = master
    }

    static func spawn(_ executable: String, _ arguments: [String], directory: String,
                      environment: [String: String]) throws -> PseudoTerminal {
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
        let argv = (["/bin/sh", "-c", #"exec "$0" "$@""#, executable] + arguments).map { strdup($0) } + [nil]
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

    func write(_ text: String) {
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
        close(master)
    }
}
