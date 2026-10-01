public struct XcodeInstall: Codable, Sendable, Equatable {
    public var path: String
    public var version: String
    public var build: String

    public init(path: String, version: String, build: String) {
        self.path = path
        self.version = version
        self.build = build
    }

    public var developerDir: String { path + "/Contents/Developer" }
    /// Betas are recognized by bundle name (Xcode-beta.app), since beta Info.plist versions have no marker.
    public var isBeta: Bool { path.lowercased().contains("beta") }
    public var summary: String { "Xcode \(version) (\(build)) \(path)" }
}
