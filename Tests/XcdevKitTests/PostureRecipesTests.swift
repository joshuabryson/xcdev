import Foundation
import Testing
@testable import XcdevKit

/// The strings Apple could rename, as data with an override.
@Suite struct PostureRecipesTests {
    let xcode271 = XcodeInstall(path: "/Applications/Xcode.app", version: "27.1", build: "27A9275")
    let xcode262 = XcodeInstall(path: "/Applications/Xcode-26.2.app", version: "26.2", build: "17C52")

    /// A temporary XCDEV_HOME with an optional override file. Returns the store and the folder to delete.
    func store(override: String?) throws -> (PostureRecipeStore, String) {
        let home = NSTemporaryDirectory() + "xcd-recipes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        if let override { try override.write(toFile: home + "/posture-recipes.json", atomically: true, encoding: .utf8) }
        return (PostureRecipeStore(globalPaths: GlobalPaths(base: home)), home)
    }

    func entry(xcode: String?, runtime: String?, feature: String) -> String {
        """
        { \(xcode.map { "\"xcode\": \"\($0)\"," } ?? "") \(runtime.map { "\"runtime\": \"\($0)\"," } ?? "")
          "feature": "\(feature)", "messageType": "IndigoVendorDefinedEvent", "usagePage": 65377, "usage": 91, "version": 0,
          "provider": "com.apple.Virtualization.VirtualMachines",
          "hinge": { "source": "hinge-slider-control", "type": "range" },
          "orientation": { "source": "orientation-picker-control", "type": "enum",
                           "values": { "portrait": "portrait", "landscape-left": "landscape-left", "landscape-right": "landscape-right" } } }
        """
    }

    func file(_ entries: [String], foldables: [String] = []) -> String {
        let types = foldables.map { "\"\($0)\"" }.joined(separator: ", ")
        return "{ \"version\": 1, \"foldableDeviceTypes\": [\(types)], \"direct\": [\(entries.joined(separator: ","))] }"
    }

    @Test func theBuiltInRecipesNameTheDuoAndTheVerifiedStrings() {
        let recipes = PostureRecipeStore.builtIn
        #expect(recipes.isFoldable(deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"))
        #expect(!recipes.isFoldable(deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"))
        #expect(!recipes.isFoldable(deviceTypeIdentifier: nil))
        let direct = PostureRecipeStore.direct(in: recipes, xcode: xcode271, runtimeVersion: "27.1")
        #expect(direct?.feature == "com.apple.coredevice.feature.remote.hid.vendordefined")
        #expect(direct?.messageType == "IndigoVendorDefinedEvent")
        #expect(direct?.usagePage == 0xff61 && direct?.usage == 0x5b && direct?.version == 0)
        #expect(direct?.provider == "com.apple.Virtualization.VirtualMachines")
        #expect(direct?.hinge.source == "hinge-slider-control" && direct?.hinge.type == "range")
        #expect(direct?.orientation.source == "orientation-picker-control" && direct?.orientation.type == "enum")
        #expect(direct?.orientation.values["landscape-left"] == "landscape-left")
        #expect(direct?.supports(.portrait) == true && direct?.supports(.portraitUpsideDown) == false)
        #expect(direct?.unsupported(.portraitUpsideDown).code == .platformUnsupported)
        #expect(direct?.unsupported(.portraitUpsideDown).next == "use one of: landscape-left, landscape-right, portrait")
    }

    @Test func theBuiltInEntryNeedsXcode27Point1AndTheRuntimeToMatch() {
        let recipes = PostureRecipeStore.builtIn
        #expect(PostureRecipeStore.direct(in: recipes, xcode: xcode262, runtimeVersion: "27.1") == nil)
        #expect(PostureRecipeStore.direct(in: recipes, xcode: xcode271, runtimeVersion: "27.0") == nil)
        #expect(PostureRecipeStore.direct(in: recipes, xcode: xcode271, runtimeVersion: "27.2") != nil)
    }

    @Test func constraintsAreBuildsRangesVersionsOrNothing() {
        #expect(RecipeConstraint.matches(nil, build: "27A9275", version: "27.1"))
        #expect(RecipeConstraint.matches("27A9275", build: "27A9275", version: "27.1"))
        #expect(!RecipeConstraint.matches("27A266a", build: "27A9275", version: "27.1"))
        #expect(RecipeConstraint.matches(">=27.1", build: nil, version: "27.1"))
        #expect(RecipeConstraint.matches(">=27.1", build: nil, version: "28.0"))
        #expect(!RecipeConstraint.matches(">=27.1", build: nil, version: "27.0"))
        #expect(RecipeConstraint.matches("<28", build: nil, version: "27.1"))
        #expect(!RecipeConstraint.matches("<28", build: nil, version: "28.0"))
        #expect(RecipeConstraint.matches("27.1", build: nil, version: "27.1.1"))
        #expect(!RecipeConstraint.matches("27.1", build: nil, version: "27.2"))
        #expect(RecipeConstraint.specificity(nil) == 0 && RecipeConstraint.specificity("27.1") == 1)
        #expect(RecipeConstraint.specificity(">=27.1") == 2 && RecipeConstraint.specificity("27A9275") == 3)
    }

    @Test func withoutAnOverrideTheBuiltInRecipesAreLoaded() throws {
        let (store, home) = try store(override: nil)
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(try store.load() == PostureRecipeStore.builtIn)
        #expect(store.overridePath == home + "/posture-recipes.json")
    }

    @Test func anOverrideThatMatchesNothingLeavesTheBuiltInEntry() throws {
        let (store, home) = try store(override: file([entry(xcode: "26.2", runtime: nil, feature: "old.feature")]))
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recipes = try store.load()
        #expect(recipes.direct.count == 2 && recipes.direct[0].feature == "old.feature")
        #expect(PostureRecipeStore.direct(in: recipes, xcode: xcode271, runtimeVersion: "27.1")?.feature
                    == "com.apple.coredevice.feature.remote.hid.vendordefined")
    }

    @Test func aBuildSpecificOverrideEntryBeatsTheBuiltInRange() throws {
        let (store, home) = try store(override: file([entry(xcode: "27A9275", runtime: nil, feature: "repaired.feature")]))
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recipes = try store.load()
        #expect(PostureRecipeStore.direct(in: recipes, xcode: xcode271, runtimeVersion: "27.1")?.feature == "repaired.feature")
    }

    @Test func anUnconstrainedOverrideEntryLosesToTheBuiltInRangeButCoversOtherXcodes() throws {
        let (store, home) = try store(override: file([entry(xcode: nil, runtime: nil, feature: "any.feature")]))
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recipes = try store.load()
        #expect(PostureRecipeStore.direct(in: recipes, xcode: xcode271, runtimeVersion: "27.1")?.feature
                    == "com.apple.coredevice.feature.remote.hid.vendordefined")
        #expect(PostureRecipeStore.direct(in: recipes, xcode: xcode262, runtimeVersion: "26.2")?.feature == "any.feature")
    }

    @Test func overrideFoldableTypesAreAddedToTheBuiltInOnes() throws {
        let (store, home) = try store(override: file([], foldables: ["com.apple.CoreSimulator.SimDeviceType.iPhone-Trio"]))
        defer { try? FileManager.default.removeItem(atPath: home) }
        let recipes = try store.load()
        #expect(recipes.isFoldable(deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Trio"))
        #expect(recipes.isFoldable(deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"))
    }

    @Test func aMalformedOverrideIsConfigInvalidNamingTheFile() throws {
        let (store, home) = try store(override: "{ \"version\": 1, \"direct\": [ { \"feature\": 7 } ] }")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let error = #expect(throws: XcdError.self) { try store.load() }
        #expect(error?.code == .configInvalid)
        #expect(error?.message == "\(home)/posture-recipes.json is not a valid posture recipe file")
        #expect(error?.next == "fix it, or delete it to use xcd's built-in recipes")
        #expect(error?.details.isEmpty == false)
    }
}
