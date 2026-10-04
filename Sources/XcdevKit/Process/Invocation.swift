import Foundation

public struct Invocation: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// Merged over the inherited environment, from which the context contract's XCD_* variables are removed first
    /// (see `ContextInfo.childEnvironment`).
    public var environment: [String: String]
    public var workingDirectory: String?
    public var timeout: Duration
    /// When set, stdout and stderr are appended to this file instead of captured; the returned output is then empty.
    public var outputFile: String?
    /// When true, reaching `timeout` ends the process and returns normally instead of throwing `.timeout`.
    public var stopAtTimeout: Bool
    /// When true, the process shares xcd's stdin, stdout, and stderr (project commands and plugins), so the
    /// returned output is empty. Takes precedence over `outputFile`.
    public var passthrough: Bool
    /// When set, stdin is read from this file instead of /dev/null.
    public var inputFile: String?

    public init(_ executable: String, _ arguments: [String], environment: [String: String] = [:],
                workingDirectory: String? = nil, timeout: Duration = .seconds(120),
                outputFile: String? = nil, stopAtTimeout: Bool = false, passthrough: Bool = false,
                inputFile: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.outputFile = outputFile
        self.stopAtTimeout = stopAtTimeout
        self.passthrough = passthrough
        self.inputFile = inputFile
    }

    /// argv with argv[0] = executable basename. Used for display and stub matching.
    public var argv: [String] { [URL(fileURLWithPath: executable).lastPathComponent] + arguments }

    public var commandLine: String { argv.map(Shell.quote).joined(separator: " ") }

    public static func git(_ args: [String], in directory: String) -> Invocation {
        Invocation("/usr/bin/git", ["-C", directory] + args, timeout: .seconds(120))
    }

    /// `DEVELOPER_DIR` selects Xcode for this subprocess only. xcd never runs `xcode-select -s`.
    public static func xcrun(_ args: [String], developerDir: String?,
                             timeout: Duration = .seconds(120)) -> Invocation {
        Invocation("/usr/bin/xcrun", args,
                   environment: developerDir.map { ["DEVELOPER_DIR": $0] } ?? [:],
                   timeout: timeout)
    }
}

public struct ProcessOutput: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    /// True when an invocation with `stopAtTimeout` was ended at its deadline. `exitCode` is then 128 + the signal
    /// (143 for SIGTERM), as for any child a signal ended, so callers that expect the stop should check this, not
    /// `succeeded`.
    public var stoppedAtDeadline = false

    public init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.init(exitCode: exitCode, stdoutData: Data(stdout.utf8), stderrData: Data(stderr.utf8))
    }

    public init(exitCode: Int32, stdoutData: Data, stderrData: Data) {
        self.exitCode = exitCode
        self.stdout = stdoutData
        self.stderr = stderrData
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
}
