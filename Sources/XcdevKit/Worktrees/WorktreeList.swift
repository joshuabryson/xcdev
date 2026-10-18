import Foundation

extension WorktreeService {
    /// Registered worktrees for one project, or for all projects when `projectRoot` is nil.
    public func list(projectRoot: String?) throws -> [RegistryEntry] {
        try registry.entries()
            .filter { projectRoot == nil || $0.projectRoot == projectRoot }
            .sorted { ($0.project, $0.name) < ($1.project, $1.name) }
    }

    /// `list` plus each worktree's branch, clones, their boot state, and the size of its `.xcdev/` folder.
    /// Boot state comes from one `simctl list` call (skipped when no worktree has clones); if it fails, states
    /// are "unknown". Sizes come from one `du` call; if it fails, sizes are left out.
    public func listDetails(projectRoot: String?) async throws -> [WorktreeListItem] {
        let loaded = try list(projectRoot: projectRoot).map(Listed.init)
        var catalog: SimCatalog?
        if loaded.contains(where: { !($0.state?.devices.isEmpty ?? true) }) {
            catalog = try? await SimctlClient(runner: runner, developerDir: nil).catalog()
        }
        let sizes = await DiskUsage(runner: runner).bytes(of: loaded.filter(\.exists).map { WorktreePaths(root: $0.entry.path).stateDirectory })
        return loaded.map { listed in
            let devices = (listed.state?.devices ?? [:]).sorted { $0.key < $1.key }.map { name, device in
                let simState = catalog.map { $0.device(udid: device.udid)?.state ?? "gone" } ?? "unknown"
                return WorktreeListItem.Device(name: name, udid: device.udid, state: simState)
            }
            let entry = listed.entry
            let status: WorktreeListItem.Status = !listed.exists ? .missing : entry.status == .ready ? .ready : .incomplete
            return WorktreeListItem(entry: entry, status: status, branch: listed.state?.branch, devices: devices,
                                    diskBytes: sizes[WorktreePaths(root: entry.path).stateDirectory])
        }
    }
}

/// A registry entry, whether its checkout is there, and the state in it.
private struct Listed {
    let entry: RegistryEntry
    let exists: Bool
    let state: WorktreeState?

    init(_ entry: RegistryEntry) {
        self.entry = entry
        exists = Disk.exists(entry.path)
        state = exists ? (try? WorktreeStateStore.load(WorktreePaths(root: entry.path))) ?? nil : nil
    }
}

/// One row of `xcd wt list`.
public struct WorktreeListItem: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ready, incomplete, missing }

    public struct Device: Codable, Sendable, Equatable {
        public let name: String
        public let udid: String
        /// simctl's state ("Booted", "Shutdown", …), "gone" if the clone no longer exists, or "unknown".
        public let state: String

        public init(name: String, udid: String, state: String) {
            self.name = name
            self.udid = udid
            self.state = state
        }
    }

    public let project: String
    public let name: String
    public let path: String
    public let status: Status
    public let branch: String?
    /// Sorted by name.
    public let devices: [Device]
    /// Size of the worktree's `.xcdev/` folder (DerivedData, logs, results), when known.
    public let diskBytes: Int64?

    public init(entry: RegistryEntry, status: Status, branch: String?, devices: [Device], diskBytes: Int64? = nil) {
        project = entry.project
        name = entry.name
        path = entry.path
        self.status = status
        self.branch = branch
        self.devices = devices
        self.diskBytes = diskBytes
    }
}
