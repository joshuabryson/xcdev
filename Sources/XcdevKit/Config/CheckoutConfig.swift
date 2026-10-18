import Foundation

/// The config a command uses in a checkout: its own `.xcdev.yml`, or, when its branch has none, the main checkout's.
public struct CheckoutConfig: Sendable {
    public let config: XcdevConfig
    /// The main checkout's `.xcdev.yml`, when it is borrowed.
    public let borrowedFrom: String?
    /// Whether the borrowed config had hooks. They were taken out: a hook's script may not be on this branch.
    let droppedHooks: Bool

    /// What every result in the checkout says about a borrowed config.
    public var note: String? {
        guard let borrowedFrom else { return nil }
        let hooks = droppedHooks ? "; its hooks don't run here until this branch has its own" : ""
        return "this branch has no \(ConfigLoader.fileName), so xcd uses the main checkout's (\(borrowedFrom))" + hooks
    }
}

extension ConfigLoader {
    /// The checkout's own config, or the main checkout's without its hooks when the checkout is a worktree whose branch
    /// has no `.xcdev.yml`. `.xcdev.local.yml` is looked for as `load` does.
    public static func checkout(worktreeRoot: String, projectRoot: String) throws -> CheckoutConfig {
        guard worktreeRoot != projectRoot, !Disk.exists(worktreeRoot + "/" + fileName) else {
            return CheckoutConfig(config: try load(worktreeRoot: worktreeRoot, projectRoot: projectRoot), borrowedFrom: nil,
                                  droppedHooks: false)
        }
        let borrowed = projectRoot + "/" + fileName
        guard Disk.exists(borrowed) else {
            throw XcdError(.configMissing, "no \(fileName) in this branch or in the main checkout (\(projectRoot))", next: setUp)
        }
        guard let main = try? String(contentsOfFile: borrowed, encoding: .utf8) else {
            throw XcdError(.configInvalid, "xcd could not read the main checkout's \(fileName) (\(borrowed)) as UTF-8 text",
                           next: "ask the user to check \(borrowed); this branch has no \(fileName) of its own and uses that one")
        }
        let local = [worktreeRoot, projectRoot].lazy
            .compactMap { try? String(contentsOfFile: $0 + "/" + localFileName, encoding: .utf8) }
            .first
        var config = try parsed(main: main, local: local, borrowed: borrowed)
        let droppedHooks = config.hooks != nil
        config.hooks = nil
        return CheckoutConfig(config: config, borrowedFrom: borrowed, droppedHooks: droppedHooks)
    }

    /// `parse`, with an error that says the `.xcdev.yml` it names is the main checkout's, since this branch has none.
    static func parsed(main: String, local: String?, borrowed: String) throws -> XcdevConfig {
        do {
            return try parse(main: main, local: local)
        } catch var error as XcdError where error.code == .configInvalid {
            error.details.append("this branch has no \(fileName), so xcd uses the main checkout's (\(borrowed))")
            error.next = "fix the file it names; the \(fileName) is the main checkout's (\(borrowed)), so ask the user before changing it"
            throw error
        }
    }
}
