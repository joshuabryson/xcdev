public enum XcodeResolver {
    /// spec: nil/"system" (xcode-select target, else newest stable), "latest" (newest stable),
    /// "beta" (newest beta), a version prefix ("27", "27.0"), or an absolute .app path.
    public static func resolve(spec rawSpec: String?, installs: [XcodeInstall],
                               selectedDeveloperDir: String?) throws -> XcodeInstall {
        let raw = rawSpec?.trimmingCharacters(in: .whitespaces) ?? "system"
        let stable = installs.filter { !$0.isBeta }
        let pick: XcodeInstall?
        switch raw.lowercased() {
        case "system":
            let selected = installs.first { install in
                guard let dir = selectedDeveloperDir else { return false }
                return dir == install.path || dir.hasPrefix(install.path + "/")
            }
            pick = selected ?? newest(stable) ?? newest(installs)
        case "latest":
            pick = newest(stable) ?? newest(installs)
        case "beta":
            pick = newest(installs.filter(\.isBeta))
        default:
            if raw.hasPrefix("/") {
                let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
                pick = installs.first { $0.path == path }
            } else if let wanted = Version(raw) {
                pick = newest(installs.filter { Version($0.version)?.hasPrefix(wanted) ?? false })
            } else {
                throw XcdError(.configInvalid, "xcode: '\(raw)' is not a valid Xcode selection",
                               next: "use a version like \"27.0\", or \"latest\", \"beta\", \"system\", or an absolute path to an Xcode .app")
            }
        }
        guard let pick else { throw missing(raw, installs) }
        return pick
    }

    static func newest(_ installs: [XcodeInstall]) -> XcodeInstall? {
        installs.max { (Version($0.version) ?? .zero) < (Version($1.version) ?? .zero) }
    }

    static func missing(_ spec: String, _ installs: [XcodeInstall]) -> XcdError {
        let sorted = installs.sorted { (Version($0.version) ?? .zero) > (Version($1.version) ?? .zero) }
        let next = newest(installs.filter { !$0.isBeta }) ?? newest(installs)
        return XcdError(.xcodeMissing, "Xcode \(spec) is not installed",
                        next: next.map { "set `xcode:` in .xcdev.yml to an installed version, e.g. \"\($0.version)\"" }
                            ?? "install Xcode from https://developer.apple.com/xcode/",
                        details: sorted.map { "installed: \($0.summary)" })
    }
}
