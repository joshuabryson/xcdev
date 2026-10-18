import Foundation

/// Bytes `wt remove` is about to delete, measured beforehand. Nil is a part that was not measured, or that
/// does not apply (the checkout, when the folder is left in place). `du` and simctl count APFS-shared copies
/// in full, so a total is an upper bound, the same way `xcd doctor` reports disk.
struct FreedDisk: Sendable, Equatable {
    var checkoutBytes: Int64?
    var stateBytes: Int64?
    var cloneBytes: Int64?

    /// `disk freed: 1.2GB (checkout 180.0MB, build state 900.0MB, simulators 120.0MB)`.
    /// Zeros are left out of the parenthetical. No measured part at all is `not measured`.
    static func line(_ checkout: Int64?, _ state: Int64?, _ clones: Int64?) -> String {
        let known = [checkout, state, clones].compactMap { $0 }
        let parts = [("checkout", checkout), ("build state", state), ("simulators", clones)].compactMap { name, value -> String? in
            guard let value, value > 0 else { return nil }
            return "\(name) \(ByteText.format(value))"
        }
        if parts.isEmpty { return known.isEmpty ? "disk freed: not measured" : "disk freed: 0B" }
        return "disk freed: \(ByteText.format(known.reduce(0, +))) (\(parts.joined(separator: ", ")))"
    }
}

/// What `du` reported for a checkout that is about to be deleted. `failed` is true when a folder that
/// exists could not be measured.
private struct TreeBytes: Sendable {
    var checkout: Int64?
    var state: Int64?
    var failed: Bool
}

extension WorktreeService {
    /// Sizes the checkout, its `.xcdev`, and its simulator clones. A folder that is already gone, with no
    /// clones to look up, is zero. A measurement that fails is nil, and when nothing positive was measured
    /// the whole result is nil so the report says `not measured` rather than `0B`.
    func freedDisk(of entry: RegistryEntry, state: WorktreeState?, keepsCheckout: Bool) async -> FreedDisk {
        let hasDevices = !(state?.devices.isEmpty ?? true)
        guard Disk.exists(entry.path) || hasDevices else { return FreedDisk(checkoutBytes: 0, stateBytes: 0, cloneBytes: 0) }
        let files = await fileBytes(path: entry.path, keepsCheckout: keepsCheckout)
        let clones = await cloneBytes(of: state)
        return Self.collapse(files, clones: clones)
    }

    private func fileBytes(path: String, keepsCheckout: Bool) async -> TreeBytes {
        guard Disk.exists(path) else { return TreeBytes(checkout: keepsCheckout ? nil : 0, state: 0, failed: false) }
        let stateDirectory = WorktreePaths(root: path).stateDirectory
        let stateExists = Disk.exists(stateDirectory)
        let countCheckout = !keepsCheckout
        var paths: [String] = []
        if countCheckout { paths.append(path) }
        if stateExists { paths.append(stateDirectory) }
        let sizes = await DiskUsage(runner: runner).bytes(of: paths)
        let stateBytes: Int64? = stateExists ? sizes[stateDirectory] : 0
        let checkoutBytes = countCheckout ? Self.checkoutSize(sizes[path], state: stateBytes, stateExists: stateExists) : nil
        let failed = (stateExists && stateBytes == nil) || (countCheckout && checkoutBytes == nil)
        return TreeBytes(checkout: checkoutBytes, state: stateBytes, failed: failed)
    }

    /// The worktree folder minus `.xcdev`. Nil when `du` did not report a size the split needs.
    private static func checkoutSize(_ tree: Int64?, state: Int64?, stateExists: Bool) -> Int64? {
        guard let tree else { return nil }
        if !stateExists { return tree }
        guard let state else { return nil }
        return max(0, tree - state)
    }

    /// Sum of `dataPathSize` for the worktree's clones. Zero when it has none. Nil when `simctl list` fails.
    private func cloneBytes(of state: WorktreeState?) async -> Int64? {
        guard let state, !state.devices.isEmpty else { return 0 }
        guard let catalog = try? await SimctlClient(runner: runner, developerDir: state.xcode?.developerDir).catalog() else { return nil }
        return state.devices.values.reduce(Int64(0)) { total, device in
            total + (catalog.device(udid: device.udid)?.dataPathSize ?? 0)
        }
    }

    /// Drops a failed measurement that found nothing, so an unknown size is not reported as zero.
    private static func collapse(_ files: TreeBytes, clones: Int64?) -> FreedDisk {
        let measured = [files.checkout, files.state, clones].compactMap { $0 }
        if (files.failed || clones == nil), !measured.contains(where: { $0 > 0 }) { return FreedDisk() }
        return FreedDisk(checkoutBytes: files.checkout, stateBytes: files.state, cloneBytes: clones)
    }
}
