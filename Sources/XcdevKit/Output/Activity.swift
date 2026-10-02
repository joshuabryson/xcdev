import Foundation
import Synchronization

/// Shows a long step on stderr: on a terminal, a spinner with the elapsed time on one redrawn line; anywhere else
/// (a pipe, TERM=dumb, `--json`), the message once as a plain `xcd: <message>` line. Never writes to stdout.
public struct Activity: Sendable {
    public static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Plain: the Services progress closure, which prints `xcd: <message>`.
    let line: @Sendable (String) -> Void
    /// Animated: raw writes to stderr, with no newline added. Nil for a plain reporter.
    let terminal: (@Sendable (String) -> Void)?
    let now: @Sendable () -> Date
    /// The terminal's width, read for each frame; nil when unknown.
    let columns: @Sendable () -> Int?
    /// Waits one frame. Throws (ending the spinner) when its task is cancelled.
    let tick: @Sendable () async throws -> Void
    /// Whether an animated step catches Ctrl-C to clear its line and remove the run's scratch folders first.
    let catchesInterrupt: Bool

    public var isAnimated: Bool { terminal != nil }

    public static func plain(_ line: @escaping @Sendable (String) -> Void) -> Activity {
        Activity(line: line, terminal: nil, now: { Date() }, columns: { nil }, tick: {}, catchesInterrupt: false)
    }

    /// Redraws about 10 times a second.
    public static func animated(write: @escaping @Sendable (String) -> Void, now: @escaping @Sendable () -> Date = { Date() },
                                columns: @escaping @Sendable () -> Int? = { nil },
                                tick: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
                                catchesInterrupt: Bool = true) -> Activity {
        Activity(line: { _ in }, terminal: write, now: now, columns: columns, tick: tick, catchesInterrupt: catchesInterrupt)
    }

    /// Scratch folders to delete if Ctrl-C ends xcd during an animated step (`xcd init` registers its own).
    private static let scratch = Mutex<Set<String>>([])

    public static func removeOnInterrupt(_ path: String) { _ = scratch.withLock { $0.insert(path) } }
    public static func keepOnInterrupt(_ path: String) { _ = scratch.withLock { $0.remove(path) } }

    /// What Ctrl-C does during an animated step: clears the line, stops the running children (`stopChildren`; they
    /// are out of the terminal's reach, and an xcodebuild left running would fill the scratch folder again), deletes
    /// the registered scratch folders, and returns the exit status, 130 (128 + SIGINT).
    static func interrupted(write: @Sendable (String) -> Void, stopChildren: () -> Void) -> Int32 {
        stopChildren()
        for path in scratch.withLock({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
        write("\r\u{1B}[K")                       // last, after the spinner has seen `fired` and stopped drawing
        return 130
    }

    /// The width of the terminal on stderr, from TIOCGWINSZ; nil when it can't be read.
    public static func stderrColumns() -> Int? {
        var size = winsize()
        guard ioctl(STDERR_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return Int(size.ws_col)
    }

    public static let silent = plain { _ in }

    /// Whether progress on stderr should animate: stderr is a terminal that isn't dumb, and the output isn't JSON.
    public static func animates(stderrIsTerminal: Bool, environment: [String: String], output: OutputFormat) -> Bool {
        stderrIsTerminal && environment["TERM"] != "dumb" && output != .json
    }

    /// Shows `message` while `body` runs. Animated, the line is replaced by `xcd: <done> (<elapsed>)` when `body`
    /// returns, and cleared when it throws, so an error message never follows a half-drawn line. Ctrl-C clears the
    /// line too, stops the running children, deletes the registered scratch folders, and exits 130.
    ///
    /// Steps must not overlap (none may start inside another, or alongside it): they would draw over each other's
    /// line, and the inner one would restore the outer one's Ctrl-C handling too early.
    public func step<T>(_ message: String, done: String, _ body: () async throws -> T) async throws -> T {
        guard let terminal else {
            line(message)
            return try await body()
        }
        let interrupts = catchesInterrupt ? InterruptHandler.install {
            exit(Self.interrupted(write: terminal, stopChildren: { SystemProcessRunner.terminateChildren() }))
        } : nil
        defer { interrupts?.remove() }
        let start = now()
        let spinner = Task { [now, columns, tick] in
            var index = 0
            while !Task.isCancelled, interrupts?.fired != true {
                terminal(Self.frame(index, message: message, elapsed: now().timeIntervalSince(start), columns: columns()))
                index += 1
                do { try await tick() } catch { break }
            }
        }
        defer { spinner.cancel() }
        do {
            let result = try await body()
            spinner.cancel()
            await spinner.value
            await Self.waitForExit(if: interrupts)
            terminal(Self.finished(done, elapsed: now().timeIntervalSince(start)))
            return result
        } catch {
            spinner.cancel()
            await spinner.value
            await Self.waitForExit(if: interrupts)
            terminal("\r\u{1B}[K")
            throw error
        }
    }

    /// Never returns once Ctrl-C fired `handler`: the body ended because its children were stopped, and the handler
    /// is about to exit, so nothing more may be printed (a result on stdout least of all).
    static func waitForExit(if handler: InterruptHandler?) async {
        while handler?.fired == true { try? await Task.sleep(for: .seconds(1)) }
    }

    /// One frame: back to the start of the line, the spinner, the message, the elapsed time, and clear the rest.
    /// The message is shortened to leave the last of `columns` free, since a line that wraps can't be redrawn.
    /// Widths are counted in Characters, which is one column each for the ASCII and braille xcd prints; wide
    /// characters (CJK, emoji) in a project's name could still make the line wrap.
    static func frame(_ index: Int, message: String, elapsed: TimeInterval, columns: Int? = nil) -> String {
        let lead = "\(frames[index % frames.count]) xcd: "
        let time = " " + seconds(elapsed)
        var shown = message
        if let columns {
            let room = columns - 1 - lead.count - time.count
            if message.count > room { shown = String(message.prefix(max(0, room - 1))) + "…" }
        }
        return "\r" + lead + shown + time + "\u{1B}[K"
    }

    /// The line that replaces the spinner when the step succeeds.
    static func finished(_ done: String, elapsed: TimeInterval) -> String {
        "\r\u{1B}[Kxcd: \(done) (\(seconds(elapsed)))\n"
    }

    /// Whole seconds: "23s", "2m05s".
    static func seconds(_ elapsed: TimeInterval) -> String {
        let whole = max(0, Int(elapsed))
        return whole < 60 ? "\(whole)s" : String(format: "%dm%02ds", whole / 60, whole % 60)
    }
}

/// Ctrl-C handling for the length of an animated step: SIGINT is ignored by the process and delivered to a
/// dispatch source instead, which runs `action`. `remove()` restores whatever handled SIGINT before.
final class InterruptHandler: Sendable {
    private let source: any DispatchSourceSignal
    private let previous: sigaction
    private let firedFlag = Mutex(false)

    /// Whether SIGINT arrived (and `action` started).
    var fired: Bool { firedFlag.withLock { $0 } }

    private init(source: any DispatchSourceSignal, previous: sigaction) {
        self.source = source
        self.previous = previous
    }

    static func install(_ action: @escaping @Sendable () -> Void) -> InterruptHandler {
        var previous = sigaction()
        var ignore = sigaction()
        ignore.__sigaction_u.__sa_handler = SIG_IGN
        sigaction(SIGINT, &ignore, &previous)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let handler = InterruptHandler(source: source, previous: previous)
        // The source holds the handler until `remove()` cancels it, which releases this closure.
        source.setEventHandler {
            handler.firedFlag.withLock { $0 = true }
            action()
        }
        source.resume()
        return handler
    }

    func remove() {
        source.cancel()
        var restore = previous
        sigaction(SIGINT, &restore, nil)
    }
}
