import ArgumentParser
import XcdevKit

enum Emit {
    /// Runs `body`, prints its result or error in the selected format, and exits with the error's code.
    /// A result that carries a task failure is printed in full, then exits with that failure's code.
    static func run<R: Reportable>(_ command: String, _ options: GlobalOptions,
                                   _ body: (Services) async throws -> R) async throws {
        var services = Services.live()
        let format = OutputFormat.resolve(jsonFlag: options.json, environment: services.environment)
        services.output = format
        do {
            let result = try await body(services)
            print(Renderer.report(result, command: command, format: format))
            if let failure = result.failure { throw ExitCode(failure.code.exitCode) }
        } catch let exit as ExitCode {
            throw exit
        } catch let error as XcdError {
            print(Renderer.failure(error, command: command, worktree: options.worktree, format: format))
            throw ExitCode(error.code.exitCode)
        } catch {
            let wrapped = XcdError(.internalError, "\(error)", next: "this is a bug in xcd; please report it")
            print(Renderer.failure(wrapped, command: command, worktree: options.worktree, format: format))
            throw ExitCode(wrapped.code.exitCode)
        }
    }
}
