import Foundation

/// Where a target runs: its platforms and, for iOS, its device families.
struct RunsOn: Equatable {
    var platforms: [AppPlatform] = []
    var families: [Int] = []
    /// Why the two aren't known; nil when they are.
    var unknown: String?
}

/// A target's build configurations and the project's, in the order Xcode applies them: the target's settings, the
/// target's .xcconfig, the project's settings, the project's .xcconfig. Plain `KEY = value` lines of .xcconfig files
/// (and the files they include) are read; values with `$(…)`, settings with SDK or architecture variants, and files
/// that can't be read leave a setting unknown.
struct BuildSettingLevels {
    let target: [[String: Any]]
    let project: [[String: Any]]
    /// The .xcconfig file a configuration is based on: nil without one, "" when its path can't be worked out.
    let baseFile: ([String: Any]) -> String?

    enum Value: Equatable { case set(String), absent, unknown(String) }
    /// Why a setting, and with it where the target runs, isn't known.
    typealias Unknown = ProjectFileReader.Unreadable

    func value(_ key: String, configuration: [String: Any]) -> Value {
        let name = configuration["name"] as? String
        let projectLevel = project.first { $0["name"] as? String == name }
        for level in [configuration, projectLevel].compactMap({ $0 }) {
            let settings = (level["buildSettings"] as? [String: Any] ?? [:]).mapValues { raw in
                (raw as? String) ?? (raw as? [String])?.joined(separator: " ") ?? "\(raw)"
            }
            if let found = Self.lookup(key, in: settings, source: nil) { return found }
            guard let file = baseFile(level) else { continue }
            let label = URL(fileURLWithPath: file).lastPathComponent
            guard !file.isEmpty else { return .unknown("its \(key) may come from an .xcconfig file that couldn't be found") }
            switch Xcconfig.settings(file) {
            case .failure(let problem): return .unknown("its \(key) may come from \(label), \(problem.reason)")
            case .success(let settings): if let found = Self.lookup(key, in: settings, source: label) { return found }
            }
        }
        return .absent
    }

    /// `key` at one level: a plain value, unknown when it's an expression or has SDK/arch variants, nil when unset.
    static func lookup(_ key: String, in settings: [String: String], source: String?) -> Value? {
        let place = source.map { " in \($0)" } ?? ""
        if settings.keys.contains(where: { $0.hasPrefix(key + "[") }) {
            return .unknown("its \(key)\(place) depends on the SDK or architecture")
        }
        guard let value = settings[key] else { return nil }
        return value.contains("$") ? .unknown("its \(key) is \(value)\(place)") : .set(value)
    }

    /// Where the target runs in every configuration, or why that isn't known (also when configurations disagree).
    func platforms(isApp: Bool) -> RunsOn {
        var seen: RunsOn?
        for configuration in target {
            let found: RunsOn
            switch devices(configuration, isApp: isApp) {
            case .failure(let why): return RunsOn(unknown: why.reason)
            case .success(let devices): found = devices
            }
            if let seen, seen != found { return RunsOn(unknown: "its build configurations build for different devices") }
            seen = found
        }
        return seen ?? RunsOn(unknown: "it has no build configurations")
    }

    /// The platforms and device families of one configuration. A Mac Catalyst app counts as an iOS app.
    func devices(_ configuration: [String: Any], isApp: Bool) -> Result<RunsOn, Unknown> {
        platformList(configuration).flatMap { listed in
            let catalyst = value("SUPPORTS_MACCATALYST", configuration: configuration) == .set("YES")
            let platforms = catalyst ? Catalyst.asIOS(listed) : listed
            return families(configuration, iOS: platforms.contains(.iOS), isApp: isApp).map { RunsOn(platforms: platforms, families: $0) }
        }
    }

    /// SUPPORTED_PLATFORMS, or without it the platform of SDKROOT.
    func platformList(_ configuration: [String: Any]) -> Result<[AppPlatform], Unknown> {
        switch value("SUPPORTED_PLATFORMS", configuration: configuration) {
        case .set(let list):
            let platforms = Set(list.split(separator: " ").compactMap { AppPlatform(sdk: String($0)) }).sorted()
            return platforms.isEmpty ? .failure(Unknown(reason: "its SUPPORTED_PLATFORMS is \(list)")) : .success(platforms)
        case .unknown(let reason): return .failure(Unknown(reason: reason))
        case .absent: return sdkPlatform(configuration).map { [$0] }
        }
    }

    func sdkPlatform(_ configuration: [String: Any]) -> Result<AppPlatform, Unknown> {
        switch value("SDKROOT", configuration: configuration) {
        case .set(let sdk):
            // "iphoneos", or with a version: "iphoneos18.0".
            guard let platform = AppPlatform(sdk: String(sdk.prefix { $0.isLetter })) else {
                return .failure(Unknown(reason: "its SDKROOT is \(sdk)"))
            }
            return .success(platform)
        case .unknown(let reason): return .failure(Unknown(reason: reason))
        case .absent: return .failure(Unknown(reason: "it sets no SDKROOT"))
        }
    }

    /// TARGETED_DEVICE_FAMILY without Mac Catalyst's value. Device families matter only for an iOS app; elsewhere
    /// they are reported when set and never make the target unknown.
    func families(_ configuration: [String: Any], iOS: Bool, isApp: Bool) -> Result<[Int], Unknown> {
        switch value("TARGETED_DEVICE_FAMILY", configuration: configuration) {
        case .set(let list):
            let families = list.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return .success(families.filter { $0 != Catalyst.deviceFamily })
        case .unknown(let reason):
            return isApp && iOS ? .failure(Unknown(reason: reason)) : .success([])
        case .absent:
            return .success(iOS ? [1] : [])                                  // the iOS SDK's default: iPhone
        }
    }
}
