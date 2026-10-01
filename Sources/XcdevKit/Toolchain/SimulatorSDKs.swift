import Foundation

/// The newest simulator SDK per platform in one Xcode (`xcodebuild -showsdks -json`).
/// An Xcode can't use a simulator runtime newer than that SDK.
public struct SimulatorSDKs: Codable, Sendable, Equatable {
    /// simctl runtime platform ("iOS", "watchOS", "tvOS", "xrOS") → SDK version ("27.0").
    public var versions: [String: String]

    public init(versions: [String: String]) { self.versions = versions }

    static let platforms = ["iphonesimulator": "iOS", "watchsimulator": "watchOS",
                            "appletvsimulator": "tvOS", "xrsimulator": "xrOS"]

    public static func parse(_ data: Data) throws -> SimulatorSDKs {
        struct SDK: Decodable {
            let platform: String
            let sdkVersion: String?
            let platformVersion: String?
        }
        let sdks: [SDK]
        do {
            sdks = try JSONDecoder().decode([SDK].self, from: data)
        } catch {
            throw XcdError(.subprocessFailed, "could not parse `xcodebuild -showsdks -json` output",
                           next: "run `xcodebuild -showsdks` to check the Xcode install", details: ["\(error)"])
        }
        var versions: [String: String] = [:]
        for sdk in sdks {
            guard let platform = platforms[sdk.platform], let version = sdk.sdkVersion ?? sdk.platformVersion else { continue }
            if let current = versions[platform], (Version(current) ?? .zero) >= (Version(version) ?? .zero) { continue }
            versions[platform] = version
        }
        return SimulatorSDKs(versions: versions)
    }

    /// Compares major.minor only, so iOS 27.0.1 runs with SDK 27.0. Platforms without an SDK are allowed
    /// (xcodebuild then explains what is missing).
    public func supports(_ runtime: SimRuntime) -> Bool {
        guard let platform = runtime.platform, let sdk = versions[platform].flatMap(Version.init),
              let version = Version(runtime.version) else { return true }
        return Version(components: Array(version.components.prefix(2))) <= sdk
    }
}

/// `SimulatorSDKs` per Xcode, cached on disk because `-showsdks` takes about a second.
public struct SDKStore: Sendable {
    public let runner: any ProcessRunning
    public let cacheDirectory: String

    public init(runner: any ProcessRunning, cacheDirectory: String) {
        self.runner = runner
        self.cacheDirectory = cacheDirectory
    }

    public func sdks(for xcode: XcodeInstall) async throws -> SimulatorSDKs {
        let key = String((xcode.build + "-" + xcode.path).map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let file = cacheDirectory + "/sdks-" + key + ".json"
        if let data = FileManager.default.contents(atPath: file),
           let cached = try? JSONCoding.decoder.decode(SimulatorSDKs.self, from: data) {
            return cached
        }
        let out = try await runner.runChecked(.xcrun(["xcodebuild", "-showsdks", "-json"], developerDir: xcode.developerDir,
                                                     timeout: .seconds(60)),
                                              next: "run `xcodebuild -showsdks` to check the Xcode install")
        let sdks = try SimulatorSDKs.parse(out.stdout)
        try? FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
        try? JSONCoding.encoder(pretty: true).encode(sdks).write(to: URL(fileURLWithPath: file), options: .atomic)
        return sdks
    }
}

/// Whether one Xcode can use a simulator runtime.
public struct RuntimeCompatibility: Sendable {
    public let xcode: XcodeInstall
    public let sdks: SimulatorSDKs

    public init(xcode: XcodeInstall, sdks: SimulatorSDKs) {
        self.xcode = xcode
        self.sdks = sdks
    }

    public func check(_ runtime: SimRuntime, device: String, installed: [SimRuntime],
                      deviceType: SimDeviceType? = nil) throws {
        guard sdks.supports(runtime) else {
            throw mismatch(runtime, device: device, installed: installed, deviceType: deviceType)
        }
    }

    /// `deviceType` narrows the suggested runtimes to ones that support it, so the hint never points at a
    /// runtime that would then fail with `runtime_missing`.
    public func mismatch(_ runtime: SimRuntime, device: String, installed: [SimRuntime],
                         deviceType: SimDeviceType? = nil) -> XcdError {
        let platform = runtime.platform ?? "?"
        let compatible = installed
            .filter { $0.isAvailable && $0.platform == runtime.platform && sdks.supports($0) && deviceType.map($0.supports) ?? true }
            .sorted { (Version($0.version) ?? .zero) < (Version($1.version) ?? .zero) }
            .map(\.name)
        return XcdError(
            .xcodeRuntimeMismatch,
            "\(runtime.name) (devices.\(device)) is newer than Xcode \(xcode.version) (\(xcode.build)) supports; its newest \(platform) simulator SDK is \(sdks.versions[platform] ?? "?")",
            next: compatible.isEmpty
                ? "set `xcode:` in .xcdev.yml (or pass --xcode) to an Xcode that supports \(runtime.name)"
                : "set devices.\(device).runtime to one of: \(compatible.joined(separator: ", ")), or use a newer Xcode via `xcode:` or --xcode",
            details: compatible.map { "compatible with Xcode \(xcode.version): \($0)" })
    }
}
