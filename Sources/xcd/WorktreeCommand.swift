import ArgumentParser
import XcdevKit

struct WorktreeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "worktree",
        abstract: "Create, list, inspect, and remove isolated worktrees (one agent per worktree).",
        subcommands: [Create.self, List.self, Status.self, Remove.self],
        aliases: ["wt"]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a worktree with its own branch and build state. Simulators are cloned on first use.")
        @Argument(help: "Worktree name, also used as the branch name.") var name: String
        @Option(help: "Git ref to branch from (default: HEAD of the main checkout).") var from: String?
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("wt create", options) { services in
                let ctx = try await services.open(worktree: options.worktree)
                let (state, created) = try await services.worktrees.create(name: name, from: from, in: ctx)
                return WorktreeCreateReport(worktree: state, created: created)
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List this project's worktrees.")
        @Flag(help: "List worktrees of every project xcd knows about.") var all = false
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("wt list", options) { services in
                if all {
                    return WorktreeListReport(worktrees: try services.worktrees.list(projectRoot: nil), includeProject: true)
                }
                let ctx = try await services.open(worktree: options.worktree)
                return WorktreeListReport(worktrees: try services.worktrees.list(projectRoot: ctx.location.projectRoot),
                                          includeProject: false)
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the current worktree's branch, Xcode, and clones.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("wt status", options) { services in
                WorktreeStatusReport(worktree: try await services.open(worktree: options.worktree).state)
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a worktree, its simulators, and its build state. The branch is kept.")
        @Argument(help: "Worktree name.") var name: String
        @Flag(help: "Remove even if the worktree has uncommitted changes (they are lost).") var force = false
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try await Emit.run("wt remove", options) { services in
                let ctx = try await services.open(worktree: options.worktree)
                return try await services.worktrees.remove(name: name, force: force, in: ctx)
            }
        }
    }
}
