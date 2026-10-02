import Foundation

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
    /// Animated only: Ctrl-C clears the line (a cleanup each step registers), after which the step draws nothing more.
    let interrupts: Interrupts?

    public var isAnimated: Bool { terminal != nil }

    public static func plain(_ line: @escaping @Sendable (String) -> Void) -> Activity {
        Activity(line: line, terminal: nil, now: { Date() }, columns: { nil }, tick: {}, interrupts: nil)
    }

    /// Redraws about 10 times a second.
    public static func animated(write: @escaping @Sendable (String) -> Void, now: @escaping @Sendable () -> Date = { Date() },
                                columns: @escaping @Sendable () -> Int? = { nil },
                                tick: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) },
                                interrupts: Interrupts = .shared) -> Activity {
        Activity(line: { _ in }, terminal: write, now: now, columns: columns, tick: tick, interrupts: interrupts)
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
    /// returns, and cleared when it throws, so an error message never follows a half-drawn line. If Ctrl-C fires the
    /// interrupt handler, it clears the line, and the step writes nothing more and doesn't return: the body ended
    /// because its children were stopped, and the handler is about to exit.
    ///
    /// Steps must not overlap (none may start inside another, or alongside it): they would draw over each other's line.
    public func step<T>(_ message: String, done: String, _ body: () async throws -> T) async throws -> T {
        guard let terminal, let interrupts else {
            line(message)
            return try await body()
        }
        let clear = interrupts.addCleanup { terminal("\r\u{1B}[K") }
        defer { interrupts.removeCleanup(clear) }
        let start = now()
        let spinner = Task { [now, columns, tick] in
            var index = 0
            while !Task.isCancelled {
                let frame = Self.frame(index, message: message, elapsed: now().timeIntervalSince(start), columns: columns())
                guard interrupts.perform({ terminal(frame) }) else { break }
                index += 1
                do { try await tick() } catch { break }
            }
        }
        defer { spinner.cancel() }
        do {
            let result = try await body()
            spinner.cancel()
            await spinner.value
            await interrupts.output { terminal(Self.finished(done, elapsed: now().timeIntervalSince(start))) }
            return result
        } catch {
            spinner.cancel()
            await spinner.value
            await interrupts.output { terminal("\r\u{1B}[K") }
            throw error
        }
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
