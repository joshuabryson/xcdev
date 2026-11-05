import Foundation
import Synchronization
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct DoctorTests: DoctorFixture {
    let fake = FakeProcessRunner()

    @Test func aHealthyMachineHasNoProblems() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let report = await doctor(project).run(fix: false, from: nil)
        #expect(report.problems.isEmpty && report.failure == nil)
        #expect(report.checks.map(\.id) == ["coresimulator", "booted-simulators", "missing-worktrees", "incomplete-worktrees", "orphaned-clones",
                                            "stuck-clones", "templates", "recordings", "ui-runners", "init-scratch", "package-caches"])   // no project check outside a project
        #expect(report.text.hasPrefix("doctor: 0 problems\nok       coresimulator\n"))
    }

    @Test func diskUsageIncludesTheMediaFolder() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        try FileManager.default.createDirectory(atPath: project.root + "/.xcdev-media/main/main", withIntermediateDirectories: true)
        try Data(count: 300_000).write(to: URL(fileURLWithPath: project.root + "/.xcdev-media/main/main/a.png"))
        let service = DoctorService(runner: RoutingRunner(fake: fake, realExecutables: ["git", "cp", "mv", "du"]),
                                    globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []))
        let disk = try #require(await service.run(fix: false, from: nil).disk)
        #expect(disk.mediaBytes >= 300_000)
        #expect(disk.text.contains(", media "))
    }

    @Test func reportText() {
        var fixed = DoctorProblem(check: "orphaned-clones", message: "xcd · A · x · iphone (U1) is orphaned: its worktree no longer exists",
                                  action: .deleteSimulator, fix: "shut it down and delete it", subject: "U1")
        fixed.fixed = true
        var failed = DoctorProblem(check: "incomplete-worktrees", message: "A/half at /w/half was left half-created",
                                   action: .discardWorktree, fix: "remove it")
        failed.fixError = "'half' has changes; inspect it"
        let manual = DoctorProblem(check: "project", message: "Xcode 26.4 is not installed (xcode_missing)",
                                   next: "set `xcode:` in .xcdev.yml to an installed version, e.g. \"27.0\"")
        let report = DoctorReport(fixMode: true, checks: [
            .init(id: "coresimulator", problems: []), .init(id: "incomplete-worktrees", problems: [failed]),
            .init(id: "orphaned-clones", problems: [fixed]), .init(id: "project", problems: [manual]),
        ], disk: DiskSummary(worktrees: [.init(project: "A", name: "main", bytes: 1_288_490_189)], clonesBytes: 3 * 1_073_741_824,
                             templatesBytes: 36_675_584))
        #expect(Renderer.report(report, command: "doctor", format: .text) == """
        doctor: 3 problems, 1 fixed
        ok       coresimulator
        failed   incomplete-worktrees  A/half at /w/half was left half-created  (fix failed: 'half' has changes; inspect it)
        fixed    orphaned-clones  xcd · A · x · iphone (U1) is orphaned: its worktree no longer exists
        problem  project  Xcode 26.4 is not installed (xcode_missing)  next: set `xcode:` in .xcdev.yml to an installed version, e.g. "27.0"
        disk: worktrees 1.2GB (A/main 1.2GB), clones 3.0GB, templates 35.0MB  (APFS clones are counted in full)
        next: set `xcode:` in .xcdev.yml to an installed version, e.g. "27.0"
        """)
        #expect(report.failure?.code == .doctorProblems && report.failure?.code.exitCode == 3)
    }

    @Test func aWorktreeDeletedByHandLeavesNothingBehindAfterFix() async throws {
        let (project, sims, worktrees, main) = try await setup()
        defer { project.remove() }
        var (feat, _) = try await worktrees.create(name: "feat", in: main)
        let clone = sims.add(name: "xcd · Sample App · feat · iphone")
        feat.devices["iphone"] = ProvisionedDevice(udid: clone, deviceType: "P", deviceTypeIdentifier: "p", runtime: "iOS", runtimeIdentifier: "r")
        try WorktreeStateStore.save(feat, WorktreePaths(root: feat.path))
        try FileManager.default.removeItem(atPath: feat.path)

        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: project.root)
        #expect(report.problems.map(\.check) == ["missing-worktrees", "orphaned-clones"])
        #expect(report.problems.allSatisfy { $0.fixed })
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["main"])
        #expect(!sims.devices.contains { $0.udid == clone })
        #expect(await doctor(project).run(fix: false, from: nil).problems.isEmpty)
    }

    /// A checkout is gone only when lstat says so and nothing stands in the way of looking.
    @Test func aCheckoutIsMissingOnlyWhenItIsReallyGone() throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        #expect(CheckoutPresence.of(project.root) == .present)
        #expect(CheckoutPresence.of(project.base + "/gone/feat") == .missing)                  // ENOENT, readable ancestor
        #expect(CheckoutPresence.of("/Volumes/xcd-unmounted-\(UUID().uuidString)/App.worktrees/feat") == .unreachable)
        // A folder that can be searched but not read, and one that can't be searched at all.
        let locked = project.base + "/locked"
        try FileManager.default.createDirectory(atPath: locked + "/inner", withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: locked)
        #expect(CheckoutPresence.of(locked + "/feat") == .unreachable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        #expect(CheckoutPresence.of(locked + "/inner") == .unreachable)
    }

    /// A worktree on a volume that isn't mounted is reported, never dropped, and its clones are spared.
    @Test func aWorktreeOnAnUnmountedVolumeIsOnlyReported() async throws {
        let (project, sims, worktrees, _) = try await setup()
        defer { project.remove() }
        let path = "/Volumes/xcd-unmounted-\(UUID().uuidString)/Sample App.worktrees/feat"
        let state = WorktreeState(id: "feat-id", name: "feat", project: "Sample App", projectRoot: project.root, path: path,
                                  branch: "feat", xcode: nil, devices: [:], status: .ready, createdAt: Date())
        try await Registry(paths: GlobalPaths(base: project.home)).upsert(RegistryEntry(state))
        let clone = sims.add(name: "xcd · Sample App · feat · iphone",
                             dataPath: try agedDevice(project.base + "/old-device", seconds: 3600))

        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: nil, includeDisk: false)
        let problem = try #require(report.problems.first)
        #expect(report.problems.count == 1 && problem.check == "missing-worktrees")
        #expect(problem.message == "Sample App/feat: \(path) can't be reached")
        #expect(problem.next == "it may be on a volume that isn't mounted, or in a folder xcd may not look into; ask the user to mount it or fix its permissions, then run `xcd doctor` again")
        #expect(problem.action == nil && !problem.fixed)
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["feat", "main"])
        #expect(sims.devices.contains { $0.udid == clone })
    }

    /// Dropping a missing worktree re-checks it under its locks and prunes git's record of it.
    @Test func droppingAMissingWorktreeRechecksItUnderItsLocks() async throws {
        let (project, _, worktrees, main) = try await setup()
        defer { project.remove() }
        let (feat, _) = try await worktrees.create(name: "feat", in: main)
        let (back, _) = try await worktrees.create(name: "back", in: main)
        try FileManager.default.removeItem(atPath: feat.path)
        let metadata = project.root + "/.git/worktrees/feat"                // git's record of the checkout
        #expect(FileManager.default.fileExists(atPath: metadata))

        try await worktrees.dropMissing(id: feat.id)
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["back", "main"])
        #expect(!FileManager.default.fileExists(atPath: metadata))

        try await worktrees.dropMissing(id: back.id)                     // its checkout is there: kept
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["back", "main"])

        try FileManager.default.removeItem(atPath: back.path)
        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "back"))
        await #expect(throws: DoctorLeftAlone.self) { try await worktrees.dropMissing(id: back.id) }
        holder.cancel()
        _ = await holder.result
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["back", "main"])
    }

    @Test func aWorktreeLeftHalfCreatedIsRemoved() async throws {
        let (project, _, worktrees, _) = try await setup()
        defer { project.remove() }
        let path = try await halfCreated("half", in: project)

        let report = await doctor(project).run(fix: true, from: project.root)
        let problem = try #require(report.problems.first { $0.check == "incomplete-worktrees" })
        #expect(problem.fixed)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["main"])
    }

    /// `wt create` runs post-worktree-create (up to 30 minutes) holding only the worktree's lock, not the project's.
    @Test(.timeLimit(.minutes(5))) func aWorktreeStillBeingCreatedIsLeftAlone() async throws {
        let (project, _, worktrees, _) = try await setup()
        defer { project.remove() }
        let path = try await halfCreated("busy", in: project)
        let note = "Sample App/busy is being created or removed by another xcd; left alone"

        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "busy"))
        let report = await doctor(project).run(fix: true, checks: [IncompleteWorktreesCheck()], from: project.root)
        holder.cancel()
        _ = await holder.result
        #expect(report.problems.isEmpty && report.failure == nil)
        #expect(report.checks.first { $0.id == "incomplete-worktrees" }?.inProgress == [note])
        #expect(report.text.contains("\nbusy     incomplete-worktrees  \(note)\n"))
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["busy", "main"])

        // Once that create is gone (killed), the same entry is a half-created worktree.
        let later = await doctor(project).run(fix: true, checks: [IncompleteWorktreesCheck()], from: project.root)
        #expect(later.problems.first { $0.check == "incomplete-worktrees" }?.fixed == true)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test(.timeLimit(.minutes(5))) func aWorktreeBeingRemovedIsLeftToItsRemove() async throws {
        let (project, _, worktrees, main) = try await setup()
        defer { project.remove() }
        let (feat, _) = try await worktrees.create(name: "feat", in: main)
        try FileManager.default.removeItem(atPath: feat.path)
        // `wt remove feat` after deleting the checkout, before dropping the entry: it holds the worktree's lock.
        let holder = try await holdLock(worktrees.lockPath(projectRoot: main.location.projectRoot, worktree: "feat"))
        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: project.root, includeDisk: false)
        holder.cancel()
        _ = await holder.result
        #expect(report.problems.isEmpty)
        #expect(report.checks.first?.inProgress == ["Sample App/feat is being created or removed by another xcd; left alone"])
        #expect(try worktrees.list(projectRoot: project.root).map(\.name) == ["feat", "main"])
    }

    /// The lock is probed once per snapshot, so detect and inProgress always agree, even if
    /// the lock is released between them.
    @Test(.timeLimit(.minutes(5))) func theBusyProbeIsTakenOncePerSnapshot() async throws {
        let (project, _, worktrees, _) = try await setup()
        defer { project.remove() }
        _ = try await halfCreated("busy", in: project)
        let holder = try await holdLock(worktrees.lockPath(projectRoot: project.root, worktree: "busy"))
        let env = await doctor(project).environment(from: nil)
        holder.cancel()
        _ = await holder.result
        #expect(env.busy == ["busy-id"])
        #expect(await IncompleteWorktreesCheck().detect(env).isEmpty)
        #expect(IncompleteWorktreesCheck().inProgress(env) == ["Sample App/busy is being created or removed by another xcd; left alone"])
    }

    /// Doctor never waits for a worktree's lock.
    @Test(.timeLimit(.minutes(5))) func withLockIfFreeNeverWaits() async throws {
        let project = try TempProject.make(config: WorktreeServiceTests.config)
        defer { project.remove() }
        let path = project.home + "/locks/probe.lock"
        #expect(!FileLock.isHeld(at: path))
        #expect(!FileManager.default.fileExists(atPath: path))                // probing never creates the file
        #expect(try await FileLock.withLockIfFree(at: path) { 7 } == 7)
        let holder = try await holdLock(path)
        #expect(FileLock.isHeld(at: path))
        #expect(try await FileLock.withLockIfFree(at: path) { 7 } == nil)
        holder.cancel()
        _ = await holder.result
        #expect(!FileLock.isHeld(at: path))
    }

    @Test func staleInitScratchIsReportedWithItsSizeAndDeletedOnlyByFix() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let now = Date()
        let cache = GlobalPaths(base: project.home).cacheDirectory
        let fm = FileManager.default
        func folder(_ name: String, age: TimeInterval) throws -> String {
            let path = cache + "/" + name
            try fm.createDirectory(atPath: path + "/.xcdev", withIntermediateDirectories: true)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: path)
            return path
        }
        let stale = [try folder("init-" + UUID().uuidString, age: 2 * 3600), try folder("init-" + UUID().uuidString, age: 26 * 3600)]
        let recent = try folder("init-" + UUID().uuidString, age: 10 * 60)
        let others = [try folder("init-notes", age: 9 * 3600), try folder("packages", age: 9 * 3600)]
        fake.stub(["du", "-sk"]) { inv in
            ProcessOutput(stdout: inv.arguments.dropFirst().map { "614400\t\($0)\n" }.joined())         // 600 MB each
        }
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), now: { now })

        let report = await service.run(fix: false, checks: [InitScratchCheck()], from: nil, includeDisk: false)
        let problem = try #require(report.problems.first)
        #expect(report.problems.count == 1 && problem.action == .deleteScratch && !problem.fixed)
        #expect(problem.message == "2 scratch folders of interrupted `xcd init` runs, older than an hour, use 1.2GB in \(cache)")
        #expect((stale + [recent] + others).allSatisfy { fm.fileExists(atPath: $0) })   // doctor alone changes nothing
        #expect(fake.calls.filter { $0.argv.first == "du" }.map { Set($0.arguments.dropFirst()) } == [Set(stale)])

        let fixed = await service.run(fix: true, checks: [InitScratchCheck()], from: nil, includeDisk: false)
        #expect(fixed.problems.count == 1 && fixed.problems[0].fixed)
        #expect(stale.allSatisfy { !fm.fileExists(atPath: $0) })
        #expect(([recent] + others).allSatisfy { fm.fileExists(atPath: $0) })
        #expect(await service.run(fix: false, checks: [InitScratchCheck()], from: nil, includeDisk: false).problems.isEmpty)
    }

    @Test func theScratchFixTriesEveryFolderAndNamesTheOnesItCouldNotDelete() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let now = Date()
        let cache = GlobalPaths(base: project.home).cacheDirectory
        let fm = FileManager.default
        var stale: [String] = []
        for _ in 0..<3 {
            let path = cache + "/init-" + UUID().uuidString
            try fm.createDirectory(atPath: path + "/.xcdev", withIntermediateDirectories: true)
            fm.createFile(atPath: path + "/.xcdev/file", contents: Data())
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: path)
            stale.append(path)
        }
        let stuck = stale.sorted()[0]                                          // the first one tried
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stuck + "/.xcdev")
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stuck + "/.xcdev") }
        fake.stub(["du", "-sk"], stdout: "")
        let service = DoctorService(runner: RoutingRunner(fake: fake), globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: fake, applicationsDirectories: []), now: { now })
        let report = await service.run(fix: true, checks: [InitScratchCheck()], from: nil, includeDisk: false)
        let problem = try #require(report.problems.first)
        #expect(!problem.fixed && problem.fixError?.hasPrefix("could not delete 1 of the scratch folders; delete them by hand: \(stuck): ") == true)
        #expect(stale.filter { fm.fileExists(atPath: $0) } == [stuck])
    }

    /// Earlier versions of xcd kept each project's Swift packages for `init` in `<home>/cache/packages/<key>`, locked
    /// by `<key>.lock`. Nothing uses them now, so all of them are reclaimable, except one whose lock an older xcd holds.
    @Test func packageCachesFromEarlierVersionsAreDeletedOnlyByFix() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let packages = GlobalPaths(base: project.home).cacheDirectory + "/packages"
        let fm = FileManager.default
        func cache(_ key: String, root: String? = nil) throws -> String {
            let directory = packages + "/" + key
            try fm.createDirectory(atPath: directory + "/SourcePackages/checkouts", withIntermediateDirectories: true)
            if let root { try root.write(toFile: directory + "/root", atomically: true, encoding: .utf8) }
            fm.createFile(atPath: directory + ".lock", contents: Data())
            return directory
        }
        let gone = try cache("Deleted-App-1f2e3d4c5b6a7980", root: project.base + "/Deleted App")
        let live = try cache("Sample-App-0123456789abcdef", root: project.root)
        let unrecorded = try cache("Who-Knows-fedcba9876543210")
        let busy = try cache("Busy-0011223344556677")
        fake.stub(["du", "-sk"]) { inv in
            ProcessOutput(stdout: inv.arguments.dropFirst().map { "1258291\t\($0)\n" }.joined())       // 1.2 GB each
        }
        let release = Counter()
        let holder = Task {
            try await FileLock.withLock(at: busy + ".lock") {
                while release.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
            }
        }
        defer { release.increment() }
        while !FileLock.isHeld(at: busy + ".lock") { try await Task.sleep(for: .milliseconds(5)) }

        let report = await doctor(project).run(fix: false, checks: [PackageCacheCheck()], from: nil, includeDisk: false)
        let check = try #require(report.checks.first)
        #expect(check.problems.map(\.subject) == [gone, live, unrecorded].sorted())
        let problem = try #require(check.problems.first { $0.subject == live })
        #expect(problem.action == .deletePackageCache && problem.fix == "delete it")
        #expect(problem.message == "the Swift package cache \(live) (1.2GB) is left over from an earlier version of xcd; "
                + "`xcd init` no longer keeps one")
        #expect(check.inProgress == ["the Swift package cache \(busy) is in use by an earlier version's `xcd init`; left alone"])
        #expect([gone, live, unrecorded, busy].allSatisfy { fm.fileExists(atPath: $0 + "/SourcePackages") })   // doctor alone deletes nothing

        let fixed = await doctor(project).run(fix: true, checks: [PackageCacheCheck()], from: nil, includeDisk: false)
        #expect(fixed.problems.count == 3 && fixed.problems.allSatisfy(\.fixed))
        #expect([gone, live, unrecorded].allSatisfy { !fm.fileExists(atPath: $0) && !fm.fileExists(atPath: $0 + ".lock") })
        #expect(fm.fileExists(atPath: busy + "/SourcePackages"))
        // Locked after doctor looked: the fix takes the lock without waiting, and leaves the cache alone.
        let late = DoctorProblem(check: "package-caches", message: "", action: .deletePackageCache, subject: busy)
        let env = await doctor(project).environment(from: nil)
        await #expect(throws: DoctorLeftAlone.self) { try await PackageCacheCheck().fix(late, env) }
        #expect(fm.fileExists(atPath: busy + "/SourcePackages"))
        release.increment()
        try await holder.value
    }

    @Test func pruneOnlyLooksForOrphans() async throws {
        let (project, sims, _, _) = try await setup()
        defer { project.remove() }
        sims.add(name: "xcd-template · iPhone 18 Pro · iOS 27.0", state: "Booted")
        let orphan = sims.add(name: "xcd · Sample App · gone · iphone")
        let report = await doctor(project).run(fix: true, checks: DoctorService.pruneChecks, from: project.root, includeDisk: false)
        #expect(report.checks.map(\.id) == ["missing-worktrees", "orphaned-clones"])
        #expect(report.problems.count == 1 && report.problems[0].subject == orphan && report.problems[0].fixed)
        #expect(report.disk == nil)
    }

    @Test func projectSetupProblemsSayWhatToDo() async throws {
        let apps = FileManager.default.temporaryDirectory.appendingPathComponent("xcd apps \(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: apps) }
        try XcodeTests.makeFakeXcode(at: apps + "/Xcode.app", version: "27.0", build: "27A266a")
        fake.stub(["mdfind"], stdout: "")
        fake.stub(["xcode-select", "-p"], stdout: apps + "/Xcode.app/Contents/Developer\n")
        var (project, _, _, main) = try await setup(config: """
        version: 1
        project: App.xcodeproj
        xcode: "26.4"
        defaultDevice: iphone
        devices:
          iphone: { type: "iPhone 99" }
          mac: { platform: macOS }
        """)
        defer { project.remove() }
        main.state.xcode = XcodeInstall(path: apps + "/Xcode-26.4.app", version: "26.4", build: "x")
        try WorktreeStateStore.save(main.state, main.paths)
        let discovery = XcodeDiscovery(runner: fake, applicationsDirectories: [apps])

        let report = await doctor(project, discovery: discovery).run(fix: false, from: project.root)
        let found = report.problems.filter { $0.check == "project" }
        #expect(found.map { $0.message.components(separatedBy: " (").last ?? "" }.contains("xcode_missing)"))
        #expect(found.contains { $0.message.hasPrefix("worktree 'main' is pinned to Xcode 26.4 (x)") && $0.action == .unpinXcode })
        #expect(found.contains { $0.message.hasPrefix("device type 'iPhone 99' (devices.iphone.type) is not available") })
        // Each one says what to do, by hand (`next:`) or with --fix.
        let xcode = try #require(found.first { $0.message.hasPrefix("Xcode 26.4 is not installed") })
        #expect(xcode.next == "set `xcode:` in .xcdev.yml to an installed version, e.g. \"27.0\"")
        let device = try #require(found.first { $0.message.hasPrefix("device type 'iPhone 99'") })
        #expect(device.next?.hasPrefix("set devices.iphone.type to one of: ") == true
                || device.next == "run `xcrun simctl list devicetypes` and set devices.iphone.type")
        let pinned = try #require(found.first { $0.action == .unpinXcode })
        #expect(pinned.fix == "unpin it, so the next command resolves `xcode:` again")
        #expect(report.failure?.next == "run `xcd doctor --fix` to fix 1 of them; the others say what to do")
        #expect(report.text.contains("problem  project  Xcode 26.4 is not installed (xcode_missing)  next: set `xcode:`"))
        #expect(report.text.contains("(--fix: unpin it, so the next command resolves `xcode:` again)"))
        #expect(try WorktreeStateStore.load(main.paths)?.xcode != nil)          // reported only, without --fix

        _ = await doctor(project, discovery: discovery).run(fix: true, checks: [ProjectCheck()], from: project.root)
        #expect(try WorktreeStateStore.load(main.paths)?.xcode == nil)
    }

    /// Re-pinned to an installed Xcode between detect and fix, the worktree keeps its pin.
    @Test func aWorktreeRepinnedMeanwhileIsNotUnpinned() async throws {
        var (project, _, _, main) = try await setup()
        defer { project.remove() }
        let installed = project.base + "/Xcode.app"
        try FileManager.default.createDirectory(atPath: installed, withIntermediateDirectories: true)
        main.state.xcode = XcodeInstall(path: project.base + "/Xcode-26.4.app", version: "26.4", build: "x")
        try WorktreeStateStore.save(main.state, main.paths)
        let env = await doctor(project).environment(from: project.root, fixing: true)
        let problem = try #require(await ProjectCheck().detect(env).first { $0.action == .unpinXcode })

        main.state.xcode = XcodeInstall(path: installed, version: "27.0", build: "27A266a")
        try WorktreeStateStore.save(main.state, main.paths)
        await #expect(throws: DoctorLeftAlone.self) { try await ProjectCheck().fix(problem, env) }
        #expect(try WorktreeStateStore.load(main.paths)?.xcode?.path == installed)
    }

    @Test func anInvalidConfigIsAProblemNotAnError() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        try project.write("version: 1\nproject: App.xcodeproj\ndevics: {}\n", to: ".xcdev.yml")
        let report = await doctor(project).run(fix: false, checks: [ProjectCheck()], from: project.root)
        #expect(report.problems.map(\.message) == [".xcdev.yml is invalid (1 problem): devics: unknown key (did you mean 'devices'?) (config_invalid)"])
        #expect(report.problems.map(\.next) == ["fix .xcdev.yml, then run `xcd config show`"])
        #expect(report.failure?.next == "fix .xcdev.yml, then run `xcd config show`")
    }

    @Test func outsideAProjectTheProjectCheckIsSkipped() async throws {
        let (project, _, _, _) = try await setup()
        defer { project.remove() }
        let report = await doctor(project).run(fix: false, checks: [ProjectCheck()], from: project.base)
        #expect(report.checks.isEmpty && report.failure == nil)
    }

    /// A plain `doctor` in a project xcd never opened writes nothing (no .xcdev/, registry,
    /// or worktree state) and runs no command that changes anything. The SDK cache is the one exception.
    @Test func doctorWithoutFixWritesNothing() async throws {
        let project = try TempProject.make(config: """
        version: 1
        project: App.xcodeproj
        xcode: "27.0"
        defaultDevice: iphone
        devices:
          iphone: { type: "iPhone 18 Pro" }
        """)
        defer { project.remove() }
        _ = try FakeSimulators(runner: fake, catalogJSON: Fixture.string("simctl-list.json"))
        let apps = project.base + "/apps"
        try XcodeTests.makeFakeXcode(at: apps + "/Xcode.app", version: "27.0", build: "27A266a")
        fake.stub(["mdfind"], stdout: "")
        fake.stub(["xcode-select", "-p"], stdout: apps + "/Xcode.app/Contents/Developer\n")
        let runner = ArgvRecorder(RoutingRunner(fake: fake))
        let service = DoctorService(runner: runner, globalPaths: GlobalPaths(base: project.home),
                                    discovery: XcodeDiscovery(runner: runner, applicationsDirectories: [apps]))
        let before = try Self.snapshot(project.base)

        #expect(try Registry(paths: GlobalPaths(base: project.home)).entries().isEmpty)    // reading a missing registry
        #expect(try Self.snapshot(project.base) == before)
        let report = await service.run(fix: false, from: project.root)

        #expect(report.checks.map(\.id).suffix(2) == ["project", "agent-docs"] && report.problems.isEmpty)
        let cache = GlobalPaths(base: project.home).cacheDirectory
        let after = try Self.snapshot(project.base)
        #expect(before.filter { after[$0.key] != $0.value }.isEmpty)               // nothing changed or removed
        let added = Set(after.keys).subtracting(before.keys)
        #expect(added.contains(project.home) && added.contains(cache))             // the SDK cache, and only it
        let cached = added.subtracting([project.home, cache])
        #expect(!cached.isEmpty && cached.allSatisfy {
            $0.hasPrefix(cache + "/sdks-") && $0.hasSuffix(".json") && !$0.dropFirst(cache.count + 1).contains("/")
        })
        #expect(!FileManager.default.fileExists(atPath: project.root + "/.xcdev"))
        #expect(!FileManager.default.fileExists(atPath: GlobalPaths(base: project.home).registryFile))

        let readOnly: [[String]] = [["git", "rev-parse"], ["xcrun", "simctl", "list"], ["mdfind"], ["xcode-select", "-p"],
                                    ["xcrun", "xcodebuild", "-showsdks"], ["du"]]
        #expect(!runner.calls.isEmpty)
        let commands = runner.calls.map { $0.starts(with: ["git", "-C"]) ? ["git"] + $0.dropFirst(3) : $0 }
        #expect(commands.filter { argv in !readOnly.contains { argv.starts(with: $0) } } == [])
    }

    /// Every file and folder under `root`: a file's contents, or "dir" for a folder.
    static func snapshot(_ root: String) throws -> [String: Data] {
        var tree: [String: Data] = [:]
        let fm = FileManager.default
        guard let paths = fm.subpaths(atPath: root) else { return tree }
        for relative in paths {
            let path = root + "/" + relative
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            tree[path] = isDirectory.boolValue ? Data("dir".utf8) : try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return tree
    }
}

/// Records every command's argv, git included, then runs it on `inner`.
private final class ArgvRecorder: ProcessRunning {
    let inner: any ProcessRunning
    private let recorded = Mutex<[[String]]>([])

    init(_ inner: any ProcessRunning) { self.inner = inner }

    var calls: [[String]] { recorded.withLock { $0 } }

    func run(_ invocation: Invocation) async throws -> ProcessOutput {
        recorded.withLock { $0.append(invocation.argv) }
        return try await inner.run(invocation)
    }
}
