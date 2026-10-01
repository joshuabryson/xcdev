import Yams

public struct WorktreeCreateReport: Reportable {
    public let worktree: WorktreeState
    public let created: Bool

    public init(worktree: WorktreeState, created: Bool) {
        self.worktree = worktree
        self.created = created
    }

    public var text: String {
        """
        worktree \(created ? "created" : "exists")  name=\(worktree.name) branch=\(worktree.branch ?? "-")
        path: \(worktree.path)
        next: cd \(Shell.quote(worktree.path))
        """
    }

    public var envelopeWorktree: String? { worktree.name }
}

public struct WorktreeListReport: Reportable {
    public let worktrees: [RegistryEntry]
    public let includeProject: Bool

    public init(worktrees: [RegistryEntry], includeProject: Bool) {
        self.worktrees = worktrees
        self.includeProject = includeProject
    }

    public var text: String {
        guard !worktrees.isEmpty else { return "no worktrees" }
        return worktrees.map { entry in
            let name = includeProject ? "\(entry.project)/\(entry.name)" : entry.name
            return "\(name)  \(entry.status.rawValue)  \(entry.path)"
        }.joined(separator: "\n")
    }
}

public struct WorktreeStatusReport: Reportable {
    public let worktree: WorktreeState

    public init(worktree: WorktreeState) { self.worktree = worktree }

    public var text: String {
        var lines = [
            "worktree \(worktree.name)  branch=\(worktree.branch ?? "-") status=\(worktree.status.rawValue)",
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
        var lines = [
            "removed worktree \(name)  devices=\(removedDevices.isEmpty ? "none" : removedDevices.joined(separator: ","))",
            "branch kept: \(branch)",
        ]
        if stateMissing {
            lines.append("note: the worktree's state was already gone, so any simulators it cloned may remain (named \"xcd · <project> · \(name) · …\")")
        }
        return lines.joined(separator: "\n")
    }
}

public struct SimReport: Reportable {
    public let action: String
    public let device: String
    public let udid: String?
    public let retries: Int
    public let worktree: String

    public init(action: String, device: String, udid: String?, retries: Int, worktree: String) {
        self.action = action
        self.device = device
        self.udid = udid
        self.retries = retries
        self.worktree = worktree
    }

    public var text: String {
        guard let udid else { return "\(device) has no clone in this worktree; nothing to do" }
        return "\(action) \(device)  udid=\(udid)" + (retries > 0 ? "  retries=\(retries)" : "")
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
