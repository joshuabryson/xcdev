import Foundation

/// The strings of the direct route that Apple could rename, kept as data.
public struct DirectRecipe: Codable, Sendable, Equatable {
    public struct Control: Codable, Sendable, Equatable {
        public var source: String
        public var type: String
    }

    public struct OrientationControl: Codable, Sendable, Equatable {
        public var source: String
        public var type: String
        /// xcd's orientation word → the pipeline's value. An orientation absent here is unsupported.
        public var values: [String: String]
    }

    /// A build ("27A9275"), a version range (">=27.1", "<28"), or an exact version; nil matches every Xcode.
    public var xcode: String?
    /// The same for the simulator runtime's version; the control names belong to the runtime.
    public var runtime: String?
    public var feature: String
    public var messageType: String
    public var usagePage: UInt64
    public var usage: UInt64
    public var version: UInt64
    public var provider: String
    public var hinge: Control
    public var orientation: OrientationControl

    public func supports(_ orientation: DeviceOrientation) -> Bool { self.orientation.values[orientation.rawValue] != nil }

    /// `platform_unsupported` for an orientation the pipeline has no value for, such as portrait-upside-down.
    public func unsupported(_ orientation: DeviceOrientation) -> XcdError {
        XcdError(.platformUnsupported, "\(orientation.rawValue) is not an orientation the foldable's pose pipeline accepts",
                 next: "use one of: " + self.orientation.values.keys.sorted().joined(separator: ", "))
    }
}

/// The recipe file's shape.
public struct PostureRecipes: Codable, Sendable, Equatable {
    public var version: Int
    public var foldableDeviceTypes: [String]
    public var direct: [DirectRecipe]

    /// Whether a device type has a hinge. The one place that asks.
    public func isFoldable(deviceTypeIdentifier: String?) -> Bool {
        deviceTypeIdentifier.map(foldableDeviceTypes.contains) ?? false
    }
}

/// Whether a recipe entry's `xcode` or `runtime` constraint accepts an install.
enum RecipeConstraint {
    /// How specific a constraint is, so the most specific matching entry wins: a build (3), a range (2), a version (1),
    /// none (0).
    static func specificity(_ constraint: String?) -> Int {
        guard let constraint else { return 0 }
        if constraint.hasPrefix(">=") || constraint.hasPrefix("<") { return 2 }
        return Version(constraint) == nil ? 3 : 1
    }

    static func matches(_ constraint: String?, build: String?, version: String) -> Bool {
        guard let constraint else { return true }
        guard let actual = Version(version) else { return constraint == build }
        if constraint.hasPrefix(">=") { return Version(String(constraint.dropFirst(2))).map { actual >= $0 } ?? false }
        if constraint.hasPrefix("<") { return Version(String(constraint.dropFirst())).map { actual < $0 } ?? false }
        if let wanted = Version(constraint) { return actual.hasPrefix(wanted) }
        return constraint == build
    }
}

/// The built-in recipes and the per-machine override at `<XCDEV_HOME>/posture-recipes.json`.
public struct PostureRecipeStore: Sendable {
    public let overridePath: String

    public init(globalPaths: GlobalPaths) { overridePath = globalPaths.base + "/posture-recipes.json" }
    public init(overridePath: String) { self.overridePath = overridePath }

    /// The override's entries before the built-in ones; a malformed override is `config_invalid`, never ignored.
    public func load() throws -> PostureRecipes {
        var recipes = Self.builtIn
        guard Disk.exists(overridePath) else { return recipes }
        let override: PostureRecipes
        do {
            override = try JSONCoding.decoder.decode(PostureRecipes.self, from: Data(contentsOf: URL(fileURLWithPath: overridePath)))
        } catch {
            throw XcdError(.configInvalid, "\(overridePath) is not a valid posture recipe file",
                           next: "fix it, or delete it to use xcd's built-in recipes",
                           details: ["\(error)"])
        }
        recipes.direct = override.direct + recipes.direct
        recipes.foldableDeviceTypes = Array(Set(override.foldableDeviceTypes + recipes.foldableDeviceTypes)).sorted()
        return recipes
    }

    /// The most specific `direct` entry for this Xcode and runtime; at equal specificity the earlier entry wins, which
    /// puts the override before the built-in.
    public static func direct(in recipes: PostureRecipes, xcode: XcodeInstall, runtimeVersion: String) -> DirectRecipe? {
        let matching = recipes.direct.enumerated().filter { _, entry in
            RecipeConstraint.matches(entry.xcode, build: xcode.build, version: xcode.version)
                && RecipeConstraint.matches(entry.runtime, build: nil, version: runtimeVersion)
        }
        return matching.max { a, b in
            let (first, second) = (RecipeConstraint.specificity(a.element.xcode), RecipeConstraint.specificity(b.element.xcode))
            return first != second ? first < second : a.offset > b.offset
        }?.element
    }

    /// What xcd ships: the strings verified on Xcode 27.1 with iOS 27.1.
    public static let builtIn = PostureRecipes(
        version: 1,
        foldableDeviceTypes: ["com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"],
        direct: [DirectRecipe(
            xcode: ">=27.1", runtime: ">=27.1",
            feature: "com.apple.coredevice.feature.remote.hid.vendordefined",
            messageType: "IndigoVendorDefinedEvent",
            usagePage: 0xff61, usage: 0x5b, version: 0,
            provider: "com.apple.Virtualization.VirtualMachines",
            hinge: DirectRecipe.Control(source: "hinge-slider-control", type: "range"),
            orientation: DirectRecipe.OrientationControl(
                source: "orientation-picker-control", type: "enum",
                values: ["portrait": "portrait", "landscape-left": "landscape-left", "landscape-right": "landscape-right"]))])
}
