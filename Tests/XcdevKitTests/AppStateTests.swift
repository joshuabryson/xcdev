import Foundation
import Testing
@testable import XcdevKit

@Suite struct AppStateTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcd-app \(UUID().uuidString)").path
    var paths: WorktreePaths { WorktreePaths(root: dir) }

    @Test func missingFileIsEmptyState() throws {
        #expect(try AppStateStore.load(paths) == AppState())
    }

    @Test func roundTrips() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let product = AppProduct(path: dir + "/DD/Build/Products/Debug-iphonesimulator/SampleApp.app",
                                 bundleId: "dev.xcdev.SampleApp", executableName: "SampleApp", platform: "iphonesimulator")
        var state = AppState()
        state.builds["iphone"] = BuildRecord(scheme: "SampleApp", configuration: nil, product: product,
                                             finishedAt: Date(timeIntervalSince1970: 1_000))
        state.lastLaunch = LaunchRecord(target: "iphone", bundleId: "dev.xcdev.SampleApp", processName: "SampleApp",
                                        pid: 4242, appLog: dir + "/app.log", launchedAt: Date(timeIntervalSince1970: 2_000))
        try AppStateStore.save(state, paths)
        #expect(try AppStateStore.load(paths) == state)
        #expect(FileManager.default.fileExists(atPath: dir + "/.xcdev/app.json"))
    }

    @Test func corruptFileIsReported() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        try "{nope".write(toFile: paths.appStateFile, atomically: true, encoding: .utf8)
        let error = #expect(throws: XcdError.self) { try AppStateStore.load(paths) }
        #expect(error?.code == .internalError)
        #expect(error?.next?.contains("app.json") == true)
    }

    @Test func executablePathDependsOnPlatform() {
        let ios = AppProduct(path: "/d/A.app", bundleId: "b", executableName: "A", platform: "iphonesimulator")
        let mac = AppProduct(path: "/d/A.app", bundleId: "b", executableName: "A", platform: "macosx")
        #expect(ios.executablePath == "/d/A.app/A" && !ios.isMac)
        #expect(mac.executablePath == "/d/A.app/Contents/MacOS/A" && mac.isMac)
    }

    @Test func artifactNamesAreTimestampedAndUnique() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 21, minute: 12, second: 5)))
        let first = paths.newArtifact(in: paths.logs, kind: "build", ext: "log", now: now)
        #expect(first == dir + "/.xcdev/logs/20260930-211205-build.log")
        FileManager.default.createFile(atPath: first, contents: nil)
        #expect(paths.newArtifact(in: paths.logs, kind: "build", ext: "log", now: now)
                == dir + "/.xcdev/logs/20260930-211205-build-2.log")
    }

    @Test func isolatedProductLivesUnderXcdevMacWithTheSuffixedId() {
        let built = AppProduct(path: "/w/.xcdev/DerivedData/Build/Products/Debug/Mac.app", bundleId: "dev.x.Mac",
                               executableName: "Mac", platform: "macosx")
        let copy = built.isolated(worktreeName: "Feature/Login", in: WorktreePaths(root: "/w"))
        #expect(copy == AppProduct(path: "/w/.xcdev/mac/Mac.app", bundleId: "dev.x.Mac.xcd-feature-login",
                                   executableName: "Mac", platform: "macosx"))
        #expect(copy.executablePath == "/w/.xcdev/mac/Mac.app/Contents/MacOS/Mac")
        #expect(WorktreePaths(root: "/w").macCopies == "/w/.xcdev/mac")
    }

    @Test func modificationDateIsTheFilesAndNilWhenNothingIsThere() throws {
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/Mac"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file)
        #expect(Disk.modificationDate(file) == date)
        #expect(Disk.modificationDate(dir + "/missing") == nil)
    }
}
