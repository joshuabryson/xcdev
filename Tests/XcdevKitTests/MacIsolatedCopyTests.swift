import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Making and refreshing `.xcdev/mac/<App>.app` under `isolation: suffix`. `ditto` runs
/// for real, so the copy is real; `codesign` is stubbed.
@Suite struct MacIsolatedCopyTests {
    let base = NSTemporaryDirectory() + "xcd-isolated-\(UUID().uuidString)"
    let fake = FakeProcessRunner()
    let reader = FakeBundleReader()
    /// What the entitlements file held when codesign ran; nil when codesign ran without one.
    let signedWith = Shared<Data?>(nil)
    /// The designated requirement every re-sign pins: the copy's identifier alone, which a rebuild keeps.
    static let requirement = #"=designated => identifier "dev.x.Mac.xcd-feature-login""#

    var paths: WorktreePaths { WorktreePaths(root: base + "/wt") }
    var source: AppProduct {
        AppProduct(path: paths.derivedData + "/Build/Products/Debug/Mac.app", bundleId: "dev.x.Mac", executableName: "Mac", platform: "macosx")
    }
    var copy: AppProduct { source.isolated(worktreeName: "Feature/Login", in: paths) }
    var entitlementsFile: String { paths.macCopies + "/Mac.entitlements.plist" }
    var copier: MacIsolatedCopy { MacIsolatedCopy(runner: RoutingRunner(fake: fake, realExecutables: ["ditto"]), reader: reader) }

    static func plist() -> [String: Any] {
        ["CFBundleIdentifier": "dev.x.Mac", "CFBundleExecutable": "Mac", "CFBundleName": "Mac", "LSMinimumSystemVersion": "15.0",
         "CFBundleURLTypes": [["CFBundleURLSchemes": ["sampleapp"]]]]
    }

    /// The built app: a binary Info.plist, as Xcode writes it; an executable holding "v1"; a provisioning profile; and a
    /// signature carrying `entitlements` (none when nil). `unsigned` leaves the signature out.
    func build(entitlements: [String: Any]? = ["com.apple.security.app-sandbox": true], extra: [String] = [], unsigned: Bool = false) throws {
        try MacBundleTests.makeBundle(at: source.path, plist: Self.plist(), format: .binary,
                                      files: ["Contents/MacOS/Mac", "Contents/embedded.provisionprofile", "Contents/Resources/Main.nib"] + extra)
        try Data("v1".utf8).write(to: URL(fileURLWithPath: source.executablePath))
        guard !unsigned else { return }
        reader.set(MacSigningInfo(identifier: "dev.x.Mac", entitlements: try entitlements.map(MacBundleTests.entitlements)), for: source.path)
    }

    /// codesign answers `exitCode`; the stub keeps what the entitlements file held when it ran.
    func stubCodesign(exitCode: Int32 = 0, stderr: String = "") {
        fake.stub(["codesign"]) { [signedWith] invocation in
            if let flag = invocation.arguments.firstIndex(of: "--entitlements") {
                signedWith.set(try Data(contentsOf: URL(fileURLWithPath: invocation.arguments[flag + 1])))
            }
            return ProcessOutput(exitCode: exitCode, stderr: stderr)
        }
    }

    func refresh() async throws -> Bool { try await copier.refresh(source: source, copy: copy, device: "mac") }

    /// A team-signed build: the two team keys are dropped from the copy's signature, the security keys kept.
    @Test func aStaleOrMissingCopyIsRemadeAndSigned() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build(entitlements: ["com.apple.security.app-sandbox": true, "com.apple.security.get-task-allow": true,
                                 "com.apple.application-identifier": "T.dev.x.Mac", "com.apple.developer.team-identifier": "T"])
        stubCodesign()
        #expect(MacIsolatedCopy.isStale(source: source, copy: copy))
        #expect(try await refresh())
        #expect(copy.path == paths.macCopies + "/Mac.app" && copy.bundleId == "dev.x.Mac.xcd-feature-login")
        #expect(try String(contentsOfFile: copy.executablePath, encoding: .utf8) == "v1")
        #expect(fake.calls.map(\.argv) == [["codesign", "--force", "--sign", "-", "--entitlements", entitlementsFile,
                                            "--requirements", Self.requirement, copy.path]])
        #expect(MacEntitlements.keys(try #require(signedWith.value)) == ["com.apple.security.app-sandbox", "com.apple.security.get-task-allow"])
    }

    @Test func aFreshCopyIsLeftAlone() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build()
        stubCodesign()
        #expect(try await refresh())
        #expect(!MacIsolatedCopy.isStale(source: source, copy: copy))
        #expect(try await refresh() == false)
        #expect(fake.calls.count == 1)
    }

    @Test func aRebuiltProductRefreshesTheCopy() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build()
        stubCodesign()
        _ = try await refresh()
        try Data("v2".utf8).write(to: URL(fileURLWithPath: source.executablePath))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: source.executablePath)
        #expect(MacIsolatedCopy.isStale(source: source, copy: copy))
        #expect(try await refresh())
        #expect(try String(contentsOfFile: copy.executablePath, encoding: .utf8) == "v2" && fake.calls.count == 2)
    }

    /// A rebuild that changes only resources leaves the executable alone; the build's last step touches the bundle folder.
    @Test func aResourceOnlyRebuildRefreshesTheCopy() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build()
        stubCodesign()
        _ = try await refresh()
        #expect(Disk.modificationDate(copy.executablePath) == Disk.modificationDate(source.executablePath))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: source.path)
        #expect(MacIsolatedCopy.isStale(source: source, copy: copy))
        #expect(try await refresh())
        #expect(fake.calls.count == 2)
    }

    @Test func aBinaryPlistStaysBinaryAndKeepsItsOtherKeys() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build()
        stubCodesign()
        _ = try await refresh()
        var format = PropertyListSerialization.PropertyListFormat.xml
        let data = try Data(contentsOf: URL(fileURLWithPath: copy.path + "/Contents/Info.plist"))
        let values = try #require(try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any])
        var expected = Self.plist()
        expected["CFBundleIdentifier"] = "dev.x.Mac.xcd-feature-login"
        #expect(format == .binary && NSDictionary(dictionary: values).isEqual(to: expected))
        #expect(MacBundle.infoPlist(of: source.path)?["CFBundleIdentifier"] as? String == "dev.x.Mac")     // the build is untouched
    }

    @Test func theProfileIsRemovedAndTheEntitlementsFileIsCleanedUp() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build()
        stubCodesign()
        _ = try await refresh()
        #expect(!FileManager.default.fileExists(atPath: copy.path + "/Contents/embedded.provisionprofile"))
        #expect(FileManager.default.fileExists(atPath: source.path + "/Contents/embedded.provisionprofile"))
        #expect(signedWith.value != nil && !FileManager.default.fileExists(atPath: entitlementsFile))
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.macCopies) == ["Mac.app"])
    }

    /// A signature without entitlements is re-signed without an entitlements file.
    @Test func aSourceWithoutEntitlementsIsSignedWithoutAFile() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build(entitlements: nil)
        stubCodesign()
        _ = try await refresh()
        #expect(fake.calls.map(\.argv) == [["codesign", "--force", "--sign", "-", "--requirements", Self.requirement, copy.path]])
        #expect(signedWith.value == nil)
    }

    @Test func aRefusedBundleMakesNoCopy() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build(extra: ["Contents/PlugIns/Share.appex/Contents/Info.plist"])
        stubCodesign()
        let error = await #expect(throws: XcdError.self) { _ = try await refresh() }
        #expect(error?.code == .configInvalid && error?.message.hasSuffix("re-identify: Contents/PlugIns/Share.appex") == true)
        #expect(fake.calls.isEmpty && !FileManager.default.fileExists(atPath: paths.macCopies))
    }

    /// A copy that fails half-way is removed: `ditto` kept the source's dates, so it would look fresh next time.
    @Test func aFailedCodesignIsASubprocessFailureNamingTheCopy() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build()
        stubCodesign(exitCode: 1, stderr: "Mac.app: invalid entitlements\n")
        let error = await #expect(throws: XcdError.self) { _ = try await refresh() }
        #expect(error?.code == .subprocessFailed && error?.message == "codesign could not re-sign \(copy.path): Mac.app: invalid entitlements")
        #expect(error?.next == "run `codesign --force --sign - \(Shell.quote(copy.path))` by hand to see why; isolation: shared needs no re-sign")
        #expect(!FileManager.default.fileExists(atPath: copy.path) && !FileManager.default.fileExists(atPath: entitlementsFile))
        #expect(MacIsolatedCopy.isStale(source: source, copy: copy))
    }

    @Test func anUnsignedSourceIsRefusedBeforeAnyCopy() async throws {
        defer { try? FileManager.default.removeItem(atPath: base) }
        try build(unsigned: true)
        stubCodesign()
        let error = await #expect(throws: XcdError.self) { _ = try await refresh() }
        #expect(error?.code == .configInvalid && error?.message == "the built app at \(source.path) is not signed, so xcd cannot re-sign a copy with its entitlements")
        #expect(fake.calls.isEmpty && !FileManager.default.fileExists(atPath: paths.macCopies) && reader.calls == [source.path])
    }
}
