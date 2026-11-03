import Foundation
import Testing
@testable import XcdevKit

extension DeviceLease {
    /// A lease for tests; every part has a default. `root` is the worktree's root path.
    static func sample(udid: String = "U1", renewedAt: Date = Date(timeIntervalSince1970: 1_791_100_000), idle: Int = 600,
                       root: String = NSTemporaryDirectory()) -> DeviceLease {
        DeviceLease(udid: udid, device: "iphone", worktree: "main", worktreeRoot: root, project: "App", developerDir: nil,
                    bootedAt: renewedAt, renewedAt: renewedAt, idle: idle)
    }
}

@Suite struct DeviceLeaseTests {
    let t0 = Date(timeIntervalSince1970: 1_791_100_000)
    let home = NSTemporaryDirectory() + "lease-\(UUID().uuidString)"
    let holds = LeaseHolds()
    var leases: DeviceLeases { DeviceLeases(globalPaths: GlobalPaths(base: home), holds: holds) }

    func state(_ devices: [String: String]) -> WorktreeState {
        let provisioned = devices.mapValues {
            ProvisionedDevice(udid: $0, deviceType: "t", deviceTypeIdentifier: "t", runtime: "r", runtimeIdentifier: "r")
        }
        return WorktreeState(id: "id", name: "main", project: "App", projectRoot: "/p", path: "/p", branch: "main", xcode: nil,
                             devices: provisioned, status: .ready, createdAt: t0)
    }

    @Test func aLeaseIsStaleOnlyPastItsIdleTime() {
        let lease = DeviceLease.sample(renewedAt: t0, idle: 600)
        #expect(!lease.isStale(now: t0 + 599, rootExists: true))
        #expect(lease.isStale(now: t0 + 600, rootExists: true))
        #expect(lease.isStale(now: t0 + 1, rootExists: false))                      // a vanished worktree
        #expect(!DeviceLease.sample(renewedAt: t0, idle: 0).isStale(now: t0 + 86_400, rootExists: false))
        #expect(!DeviceLease.sample(renewedAt: t0 + 3600, idle: 600).isStale(now: t0, rootExists: true))
        #expect(DeviceLease.sample(renewedAt: t0 + 3600, idle: 600).quietSeconds(now: t0) == 0)
    }

    @Test func aLeaseIsKeptPerUdidAndRoundTrips() throws {
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600))
        #expect(leases.load("U1") == .sample(udid: "U1", renewedAt: t0, idle: 600))
        #expect(leases.files("U1").lease == home + "/devices/U1/lease.json")
        #expect(leases.files("U1").lock == home + "/devices/U1/lease.lock")
    }

    @Test func anUnreadableLeaseReadsAsNone() throws {
        try Disk.makeFolder(leases.files("U1").folder)
        try Data("{".utf8).write(to: URL(fileURLWithPath: leases.files("U1").lease))
        #expect(leases.load("U1") == nil)
    }

    @Test func renewalTouchesOnlyLeasesThatExist() throws {
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600))
        leases.renew(["U1", "U2"], now: t0 + 60)
        #expect(leases.load("U1")?.renewedAt == t0 + 60)
        #expect(leases.load("U2") == nil)
    }

    @Test func keepingAWorktreeHoldsEveryLeaseAndRenewsOnlyWhenAsked() async throws {
        let state = state(["iphone": "K1", "watch": "K2", "ipad": "K3"])      // K3 has no lease
        try leases.save(.sample(udid: "K1", renewedAt: t0, idle: 600))
        try leases.save(.sample(udid: "K2", renewedAt: t0, idle: 600))
        try await leases.keep(state, renewing: false, now: t0 + 60)
        #expect(leases.load("K1")?.renewedAt == t0)
        #expect(holds.isHolding("K1") && holds.isHolding("K2") && !holds.isHolding("K3"))
        #expect(FileLock.isHeld(at: leases.files("K2").lock))
        try await leases.keep(state, renewing: true, now: t0 + 120)
        #expect(leases.load("K1")?.renewedAt == t0 + 120)
        #expect(leases.load("K2")?.renewedAt == t0 + 120)
        holds.release("K1"); holds.release("K2")
        #expect(!FileLock.isHeld(at: leases.files("K1").lock))
    }

    @Test func removingASessionKeepsItsLockFile() throws {
        try leases.save(.sample(udid: "U1", renewedAt: t0, idle: 600))
        leases.remove("U1")
        #expect(leases.load("U1") == nil)
        #expect(Disk.exists(leases.files("U1").folder))
    }
}
