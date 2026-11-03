import Foundation
import Yams

public struct WorktreeCreateReport: Reportable {
    public let worktree: WorktreeState
    public let created: Bool
    public let branchCreated: Bool
    public let packagesSeeded: Bool
    public let hookRan: Bool

    public init(worktree: WorktreeState, created: Bool, branchCreated: Bool = false,
                packagesSeeded: Bool = false, hookRan: Bool = false) {
        self.worktree = worktree
        self.created = created
        self.branchCreated = branchCreated
        self.packagesSeeded = packagesSeeded
        self.hookRan = hookRan
    }

    public init(_ made: CreatedWorktree) {
        self.init(worktree: made.state, created: made.created, branchCreated: made.branchCreated,
                  packagesSeeded: made.packagesSeeded, hookRan: made.hookRan)
    }

    public var text: String {
        var lines = [
            "worktree \(created ? "created" : "exists")  name=\(worktree.name) branch=\(worktree.branch ?? "-")",
            "path: \(worktree.path)",
        ]
        if created { lines.append("setup: " + setup) }
        lines.append("next: cd \(Shell.quote(worktree.path)), then run xcd build, xcd test, or xcd run")
        return lines.joined(separator: "\n")
    }

    /// What this command set up. Only the clauses that happened are included.
    private var setup: String {
        var parts = [branchClause, "DerivedData at .xcdev/DerivedData, empty until the first build",
                     "simulators clone on first use"]
        if packagesSeeded { parts.append("source packages copied from the main checkout") }
        if hookRan { parts.append("post-worktree-create ran") }
        return parts.joined(separator: "; ")
    }

    private var branchClause: String {
        guard branchCreated else { return "existing branch \(worktree.branch ?? worktree.name)" }
        return worktree.base.map { "new branch from \($0)" } ?? "new branch \(worktree.branch ?? worktree.name)"
    }

    public var envelopeWorktree: String? { worktree.name }
}

public struct WorktreeListReport: Reportable {
    public let worktrees: [WorktreeListItem]
    public let includeProject: Bool

    public init(worktrees: [WorktreeListItem], includeProject: Bool) {
        self.worktrees = worktrees
        self.includeProject = includeProject
    }

    public var text: String {
        guard !worktrees.isEmpty else { return "no worktrees" }
        return worktrees.map { item in
            let name = includeProject ? "\(item.project)/\(item.name)" : item.name
            let devices = item.devices.isEmpty ? "none" : item.devices.map { "\($0.name):\($0.state)" }.joined(separator: ",")
            let disk = item.diskBytes.map { "  disk=" + ByteText.format($0) } ?? ""
            return "\(name)  \(item.status.rawValue)  branch=\(item.branch ?? "-")  devices=\(devices)\(disk)  \(item.path)"
        }.joined(separator: "\n")
    }
}

public struct WorktreeStatusReport: Reportable {
    public let worktree: WorktreeState

    public init(worktree: WorktreeState) { self.worktree = worktree }

    public var text: String {
        var lines = [
            "worktree \(worktree.name)  branch=\(worktree.branch ?? "-") status=\(worktree.status.rawValue)"
                + (worktree.hookPending == true ? " hook=pending" : ""),
            "path: \(worktree.path)",
        ]
        if let xcode = worktree.xcode {
            lines.append("xcode: \(xcode.version) (\(xcode.build)) \(xcode.path)")
        } else {
            lines.append("xcode: not pinned yet (resolved on first simulator or build use)")
        }
        if worktree.devices.isEmpty {
            lines.append("devices: none cloned yet (cloned on first use)")
        }
        for (name, device) in worktree.devices.sorted(by: { $0.key < $1.key }) {
            lines.append("device \(name): \(device.deviceType), \(device.runtime)  udid=\(device.udid)")
        }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree.name }
}

extension WorktreeRemoval: Reportable {
    public var text: String {
        let devices = "devices=\(removedDevices.isEmpty ? "none" : removedDevices.joined(separator: ","))"
        let keptLine = checkoutGone ? "the checkout at \(path) was already gone"
            : branch.map { "the checkout at \(path) and its branch \($0) are left to whatever made them" }
            ?? "the checkout at \(path), on a detached HEAD, is left to whatever made it"
        var lines = keptCheckout
            ? ["removed xcd's state for \(name)  " + devices, keptLine]
            : ["removed worktree \(name)  " + devices, "branch kept: \(branch ?? name)"]
        lines.append(FreedDisk.line(checkoutBytes, stateBytes, cloneBytes))
        if stateMissing {
            lines.append("note: the worktree's state was already gone, so any simulators it cloned may remain (named \"xcd · \(project) · \(name) · …\")")
        }
        lines += stoppedRecordings
        lines += stoppedRunners
        lines += warnings.map { "warning: " + $0 }
        return lines.joined(separator: "\n")
    }
}

public struct SimReport: Reportable {
    public let action: String
    public let device: String
    public let udid: String?
    public let retries: Int
    public let worktree: String
    public var notes: [String] = []
    /// Seconds of silence before the clone shuts itself down; 0 is never. Set by `sim boot`.
    public var idle: Int?

    public init(action: String, device: String, udid: String?, retries: Int, worktree: String, notes: [String] = []) {
        self.notes = notes
        self.action = action
        self.device = device
        self.udid = udid
        self.retries = retries
        self.worktree = worktree
    }

    public var text: String {
        guard let udid else { return "\(device) has no clone in this worktree; nothing to do" }
        return (["\(action) \(device)  udid=\(udid)" + (retries > 0 ? "  retries=\(retries)" : "")] + notes).joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree }
}

public struct ConfigReport: Reportable {
    public let config: XcdevConfig
    public let worktree: WorktreeState

    public init(config: XcdevConfig, worktree: WorktreeState) {
        self.config = config
        self.worktree = worktree
    }

    public var text: String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        var lines = [((try? encoder.encode(config)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
        lines.append("# pinned in worktree '\(worktree.name)':")
        if let xcode = worktree.xcode {
            lines.append("#   xcode: \(xcode.version) (\(xcode.build)) \(xcode.path)")
        } else {
            lines.append("#   xcode: not pinned yet")
        }
        for (name, device) in worktree.devices.sorted(by: { $0.key < $1.key }) {
            lines.append("#   \(name): \(device.deviceType), \(device.runtime) (\(device.udid))")
        }
        return lines.joined(separator: "\n")
    }

    public var envelopeWorktree: String? { worktree.name }
}
