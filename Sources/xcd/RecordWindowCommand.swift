import ArgumentParser
import XcdevKit

/// The detached recorder `xcd ui record start` spawns for a Mac app. Hidden from help. Its stdout and stderr are the
/// recording's log, so a failure is written there for `record start` to show.
struct RecordWindowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: MacWindowRecorder.marker, abstract: "Record one window until SIGINT.",
                                                    shouldDisplay: false)
    @Option(help: "The window id.") var window: UInt32
    @Option(help: "Where the MP4 goes.") var out: String
    @Option(help: "Pixels per point.") var scale: Double = 2

    func run() async throws {
        do {
            try await MacWindowRecorder.record(windowID: window, to: out, scale: scale)
        } catch {
            let failure = error as? XcdError
                ?? XcdError(.runnerFailed, error.localizedDescription, next:"run `xcd doctor`, then start the recording again")
            StandardError.write(Renderer.failure(failure, command: MacWindowRecorder.marker, format: .text) + "\n")
            throw ExitCode(failure.code.exitCode)
        }
    }
}
