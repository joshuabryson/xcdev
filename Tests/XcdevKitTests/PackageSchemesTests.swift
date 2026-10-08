import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// The schemes Xcode gives a Swift package, each case as `xcodebuild -list` (Xcode 27.0) answered for a package
/// named Notes with these products and targets.
@Suite struct PackageSchemesTests {
    /// What `swift package dump-package` prints for the package, reduced to what `PackageLayout` reads.
    /// A product is (name, type, targets); a target is (name, type).
    func package(products: [(String, String, [String])] = [], targets: [(String, String)]) throws -> PackageLayout {
        let dump: [String: Any] = [
            "name": "Notes",
            "products": products.map { ["name": $0.0, "type": [$0.1: NSNull()], "targets": $0.2] as [String: Any] },
            "targets": targets.map { ["name": $0.0, "type": $0.1, "dependencies": [Any]()] as [String: Any] },
        ]
        return try PackageLayout.parse(JSONSerialization.data(withJSONObject: dump))
    }

    /// With no product there is nothing to name a scheme for, and Xcode lists only the one that builds everything.
    @Test func aRootPackageWithoutProductsHasOnlyThePackageScheme() throws {
        #expect(try package(targets: [("Notes", "regular")]).schemes(as: .root) == ["Notes-Package"])
        #expect(try package(targets: [("One", "regular"), ("Two", "regular")]).schemes(as: .root) == ["Notes-Package"])
        #expect(try package(targets: [("Notes", "regular"), ("NotesTests", "test")]).schemes(as: .root) == ["Notes-Package"])
        // A plugin product gets no scheme, so it doesn't count.
        #expect(try package(products: [("Gen", "plugin", ["Gen"])], targets: [("Gen", "plugin")]).schemes(as: .root) == ["Notes-Package"])
    }

    /// `init` writes the first of the detected schemes as the one to build, so it has to be one xcodebuild knows.
    @Test func initBuildsAPackageWithoutProductsWithItsPackageScheme() async throws {
        let detection = ProjectDetectionTests()
        defer { detection.cleanUp() }
        try detection.make(["Package.swift"])
        detection.fake.stub(["xcrun", "swift", "package"], stdout: """
            {"name": "Notes", "platforms": [], "products": [],
             "targets": [{"name": "Notes", "type": "regular", "dependencies": []},
                         {"name": "NotesTests", "type": "test", "dependencies": [{"byName": ["Notes", null]}]}]}
            """)
        let detected = try await detection.detector().detect(root: detection.root, container: "Package.swift")
        #expect(detected.schemes == ["Notes-Package"])
        #expect(detected.appSchemes == ["Notes-Package"] && detected.testSchemes == ["Notes-Package"])
    }

    @Test func aRootPackageWithOneProductHasOneSchemeNamedForThePackage() throws {
        #expect(try package(products: [("NotesKit", "library", ["NotesKit"])], targets: [("NotesKit", "regular")])
            .schemes(as: .root) == ["Notes"])
        #expect(try package(products: [("NotesKit", "library", ["NotesKit"])],
                            targets: [("NotesKit", "regular"), ("Extra", "regular"), ("NotesKitTests", "test")])
            .schemes(as: .root) == ["Notes"])
        #expect(try package(products: [("Lib", "library", ["Lib"]), ("Gen", "plugin", ["Gen"])],
                            targets: [("Lib", "regular"), ("Gen", "plugin")])
            .schemes(as: .root) == ["Notes"])
        // An executable target is a product without being declared one.
        #expect(try package(targets: [("tool", "executable")]).schemes(as: .root) == ["Notes"])
        #expect(try package(targets: [("tool", "executable"), ("Lib", "regular")]).schemes(as: .root) == ["Notes"])
    }

    @Test func aRootPackageWithSeveralProductsHasASchemeForEachAndOneForAll() throws {
        #expect(try package(products: [("One", "library", ["One"]), ("Two", "library", ["Two"])],
                            targets: [("One", "regular"), ("Two", "regular")])
            .schemes(as: .root) == ["One", "Two", "Notes-Package"])
        #expect(try package(targets: [("one", "executable"), ("two", "executable")]).schemes(as: .root)
                == ["one", "two", "Notes-Package"])
        #expect(try package(products: [("tool", "executable", ["tool"])], targets: [("tool", "executable"), ("other", "executable")])
            .schemes(as: .root) == ["tool", "other", "Notes-Package"])
    }

    /// An executable product may be named differently from its target. The target is then no product of its own.
    @Test func anExecutableTargetThatAProductHoldsGetsNoSchemeOfItsOwn() throws {
        let renamed = try package(products: [("notes", "executable", ["tool"])], targets: [("tool", "executable")])
        #expect(renamed.schemes(as: .root) == ["Notes"])
        #expect(renamed.schemes(as: .folder) == ["notes"])
        let withLibrary = try package(products: [("notes", "executable", ["tool"]), ("Lib", "library", ["Lib"])],
                                      targets: [("tool", "executable"), ("Lib", "regular")])
        #expect(withLibrary.schemes(as: .root) == ["notes", "Lib", "Notes-Package"])
        #expect(withLibrary.schemes(as: .folder) == ["notes", "Lib"])
        #expect(withLibrary.schemes(as: .packageReference) == ["notes", "Lib"])
    }
}
