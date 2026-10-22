import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// Where a Mac app's data is, from its signature's entitlements.
@Suite struct MacContainerTests {
    let reader = FakeBundleReader()
    static let elsewhere = "its preferences are the dev.x.Mac domain (`defaults read dev.x.Mac`) and its files are under "
        + "~/Library/Application Support/Mac and ~/Library/Caches/dev.x.Mac"

    /// The container of the build at `app`, whose executable is `Mac`.
    func path(_ app: String) throws -> String {
        let built = AppProduct(path: app, bundleId: "dev.x.Mac", executableName: "Mac", platform: "macosx")
        return try MacContainer.path(bundleId: "dev.x.Mac", built: built, reader: reader, home: "/Users/u")
    }

    @Test func aSandboxedAppsContainerIsUnderLibraryContainers() throws {
        reader.set(try MacIsolationServiceTests.sandboxed(), for: "/w/Mac.app")
        #expect(try path("/w/Mac.app") == "/Users/u/Library/Containers/dev.x.Mac/Data")
    }

    @Test func anUnsandboxedAppIsAUsageErrorNamingItsDefaultsDomainAndFolders() throws {
        let plain = try PropertyListSerialization.data(fromPropertyList: ["com.apple.security.get-task-allow": true],
                                                       format: .xml, options: 0)
        reader.set(MacSigningInfo(identifier: "dev.x.Mac", entitlements: plain), for: "/w/Mac.app")
        reader.set(MacSigningInfo(identifier: "dev.x.Mac", entitlements: nil), for: "/w/Bare.app")
        for app in ["/w/Mac.app", "/w/Bare.app"] {
            let error = #expect(throws: XcdError.self) { try path(app) }
            #expect(error?.code == .usage && error?.message == "dev.x.Mac is not sandboxed, so it has no container: " + Self.elsewhere)
            #expect(error?.next == "look there, or add the App Sandbox capability to the app")
        }
    }

    /// Without a signature xcd cannot tell whether the app is sandboxed, so it says so and names no folder as the answer.
    @Test func anUnsignedAppIsAUsageErrorSayingSo() throws {
        reader.set(nil, for: "/w/Mac.app")
        let error = #expect(throws: XcdError.self) { try path("/w/Mac.app") }
        #expect(error?.code == .usage)
        #expect(error?.message == "dev.x.Mac is not signed, so xcd cannot read its entitlements and does not know whether it has a container")
        #expect(error?.next == "sign the build (Xcode's Sign to Run Locally is enough), or look under ~/Library/Containers/dev.x.Mac/Data yourself")
    }
}
