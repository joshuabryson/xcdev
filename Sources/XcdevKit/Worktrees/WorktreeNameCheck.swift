import Foundation

extension WorktreeService {
    /// The project's entry that has this name, after refusing a name that would take another tool's checkout or differ
    /// from an existing worktree's only in case, where lock files would be the same.
    func checkName(_ name: String, in ctx: WorktreeContext) throws -> RegistryEntry? {
        let entries = try registry.entries().filter { $0.projectRoot == ctx.location.projectRoot }
        if let existing = entries.first(where: { $0.name == name }) {
            guard !isXcds(existing, in: ctx) else { return existing }
            throw foreign(existing)
        }
        if name.lowercased() == "main" {
            throw XcdError(.usage, "'\(name)' is the main checkout's name but for case", next: "pick another name")
        }
        if let other = entries.first(where: { $0.name.lowercased() == name.lowercased() }) {
            throw XcdError(.usage, "'\(name)' differs only in case from worktree '\(other.name)', and their lock files would be the same on this Mac",
                           next: "pick another name")
        }
        return nil
    }

    /// A name that is already another tool's checkout, whose folder may be gone.
    private func foreign(_ existing: RegistryEntry) -> XcdError {
        let name = existing.name
        let message = "'\(name)' is the name xcd gave a checkout it did not make, at \(existing.path); it may be another agent's"
        guard Disk.exists(existing.path) else {
            return XcdError(.usage, message, next: "run `xcd wt remove \(name)` to drop xcd's record of the checkout that was at "
                + "\(existing.path), or pick another name")
        }
        return XcdError(.usage, message, next: "pick another name for the new worktree; ask the user before working in \(existing.path)")
    }

    /// The checkout's own config, which its hooks (and their scripts) come from, or nil when it has no
    /// .xcdev.yml. Never the caller's config: the hook's script may not exist on this checkout's branch.
    func hookConfig(worktree: String, projectRoot: String) throws -> XcdevConfig? {
        do {
            return try ConfigLoader.load(worktreeRoot: worktree, projectRoot: projectRoot)
        } catch let error as XcdError where error.code == .configMissing {
            return nil
        }
    }
}
