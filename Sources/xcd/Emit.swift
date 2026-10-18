import ArgumentParser
import XcdevKit

enum Emit {
    /// Runs `body`, prints its result or error in the selected format with the notes added while it ran, and exits
    /// with the error's code.
    static func run<R: Reportable>(_ command: String, _ options: GlobalOptions,
                                   _ body: (Services) async throws -> R) async throws {
        var services = Services.live()
        services.output = OutputFormat.resolve(jsonFlag: options.json, environment: services.environment)
        try await Notes.$current.withValue(services.notes) { try await emit(command, options, services, body) }
    }

    /// A result that carries a task failure is printed in full, then exits with that failure's code.
    /// Nothing is printed once Ctrl-C has fired the interrupt handler, which then exits instead.
    private static func emit<R: Reportable>(_ command: String, _ options: GlobalOptions, _ services: Services,
                                            _ body: (Services) async throws -> R) async throws {
        let format = services.output
        do {
            let result = try await body(services)
            await services.interrupts.output { print(Renderer.report(result, command: command, format: format)) }
            StandardError.write(Renderer.standardErrorLines(for: result, format: format))
            if let failure = result.failure { throw ExitCode(failure.code.exitCode) }
        } catch let exit as ExitCode {
            await services.interrupts.output {}                              // the handler's code wins
            throw exit
        } catch let error as XcdError {
            await services.interrupts.output {
                print(Renderer.failure(error, command: command, worktree: options.worktree, format: format))
            }
            throw ExitCode(error.code.exitCode)
        } catch {
            let wrapped = XcdError(.internalError, "\(error)", next: "this is a bug in xcd; please report it")
            await services.interrupts.output {
                print(Renderer.failure(wrapped, command: command, worktree: options.worktree, format: format))
            }
            throw ExitCode(wrapped.code.exitCode)
        }
    }
}
