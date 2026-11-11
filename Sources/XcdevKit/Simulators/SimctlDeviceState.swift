import Foundation

public enum PrivacyAction: String, Codable, Sendable, CaseIterable { case grant, revoke, reset }

public enum Appearance: String, Codable, Sendable, CaseIterable { case light, dark }

public struct Coordinate: Codable, Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// "37.33,-122.03": what simctl's `location set` takes.
    public var text: String { "\(latitude),\(longitude)" }

    /// `<lat>,<lon>` with `.` decimals; a `usage` error otherwise.
    public static func parse(_ text: String) throws -> Coordinate {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw XcdError(.usage, "'\(text)' is not a latitude,longitude pair",
                           next: "pass decimal degrees with a comma between, e.g. `xcd sim location 37.33,-122.03`")
        }
        return Coordinate(latitude: lat, longitude: lon)
    }
}

/// `xcd sim status-bar` values, mapped to `simctl status_bar override` flags.
public struct StatusBarOverrides: Codable, Sendable, Equatable {
    public var time: String?
    public var batteryLevel: Int?
    public var batteryState: String?
    public var wifiBars: Int?
    public var cellularBars: Int?
    public var network: String?
    public var operatorName: String?

    public static let batteryStates = ["charged", "charging", "discharging"]
    public static let networks = ["hide", "wifi", "3g", "4g", "lte", "lte-a", "lte+", "5g", "5g+", "5g-uwb", "5g-uc"]

    public init(time: String? = nil, batteryLevel: Int? = nil, batteryState: String? = nil, wifiBars: Int? = nil,
                cellularBars: Int? = nil, network: String? = nil, operatorName: String? = nil) {
        self.time = time
        self.batteryLevel = batteryLevel
        self.batteryState = batteryState
        self.wifiBars = wifiBars
        self.cellularBars = cellularBars
        self.network = network
        self.operatorName = operatorName
    }

    public var isEmpty: Bool { self == StatusBarOverrides() }

    /// simctl's override flags in a fixed order. A value out of range is `usage`.
    public func arguments() throws -> [String] {
        guard !isEmpty else {
            throw XcdError(.usage, "no status bar values given",
                           next: "pass at least one of --time, --battery, --battery-state, --wifi, --cellular, --network, --operator, or --clear")
        }
        func range(_ value: Int?, _ bounds: ClosedRange<Int>, _ flag: String) throws {
            if let value, !bounds.contains(value) {
                throw XcdError(.usage, "\(flag) \(value) is out of range", next: "use \(bounds.lowerBound)-\(bounds.upperBound)")
            }
        }
        func oneOf(_ value: String?, _ allowed: [String], _ flag: String) throws {
            if let value, !allowed.contains(value) {
                throw XcdError(.usage, "\(flag) \(value) is not a valid value", next: "use one of: " + allowed.joined(separator: ", "))
            }
        }
        try range(batteryLevel, 0...100, "--battery")
        try range(wifiBars, 0...3, "--wifi")
        try range(cellularBars, 0...4, "--cellular")
        try oneOf(batteryState, Self.batteryStates, "--battery-state")
        try oneOf(network, Self.networks, "--network")
        var args: [String] = []
        if let time { args += ["--time", time] }
        if let batteryLevel { args += ["--batteryLevel", String(batteryLevel)] }
        if let batteryState { args += ["--batteryState", batteryState] }
        if let wifiBars { args += ["--wifiBars", String(wifiBars)] }
        if let cellularBars { args += ["--cellularBars", String(cellularBars)] }
        if let network { args += ["--dataNetwork", network] }
        if let operatorName { args += ["--operatorName", operatorName] }
        return args
    }

    /// "time=9:41 battery=100", for reports.
    public var summary: String {
        var parts: [String] = []
        if let time { parts.append("time=\(time)") }
        if let batteryLevel { parts.append("battery=\(batteryLevel)") }
        if let batteryState { parts.append("battery-state=\(batteryState)") }
        if let wifiBars { parts.append("wifi=\(wifiBars)") }
        if let cellularBars { parts.append("cellular=\(cellularBars)") }
        if let network { parts.append("network=\(network)") }
        if let operatorName { parts.append("operator=\(operatorName)") }
        return parts.joined(separator: " ")
    }
}

extension SimctlClient {
    /// The services `simctl help privacy` lists. simctl accepts some it doesn't list (camera), so xcd doesn't reject others.
    public static let privacyServices = ["all", "calendar", "contacts", "contacts-limited", "location", "location-always",
                                         "photos", "photos-add", "media-library", "microphone", "motion", "reminders", "siri"]

    /// How many times `openurl` is run while simctl gives up waiting, about 10 s each: about a minute in all.
    static let openURLTries = 6

    public func openURL(udid: String, url: String) async throws {
        let invocation = simctl(["openurl", udid, url])
        var out = try await runner.run(invocation)
        // Safari can be slow to launch on a freshly booted clone; simctl then gives up with exit 60 ("Operation timed out").
        for _ in 1..<Self.openURLTries where Self.timedOut(out) {
            out = try await runner.run(invocation)
        }
        guard !out.succeeded else { return }
        if Self.timedOut(out) {
            throw XcdError.subprocess(invocation, out, code: .simulatorFailed, message: "the simulator took too long to open \(url)",
                                      next: "the simulator may still be starting up; wait a few seconds and retry, or run `xcd doctor`")
        }
        let scheme = url.split(separator: ":", maxSplits: 1).first.map(String.init) ?? url
        let next = out.stderrString.contains("LSApplicationWorkspaceErrorDomain")
            ? "no app on this simulator opens \(scheme): URLs; install the app that registers it (`xcd install`), or check the URL"
            : "pass a full URL with a scheme, e.g. https://example.com or myapp://path"
        throw XcdError.subprocess(invocation, out, code: .simulatorFailed, message: "the simulator could not open \(url)", next: next)
    }

    private static func timedOut(_ out: ProcessOutput) -> Bool {
        out.exitCode == 60 || out.stderrString.contains("Operation timed out")
    }

    public func push(udid: String, bundleId: String, payloadFile: String) async throws {
        let invocation = simctl(["push", udid, bundleId, payloadFile])
        let out = try await runner.run(invocation)
        guard !out.succeeded else { return }
        let next = out.stderrString.contains("not authorized")
            ? "the simulator refused the notification (\"Source is not authorized\"): install the app with `xcd install` or `xcd run`, and have it ask for notification permission first"
            : "check the payload: a JSON object with an \"aps\" key, 4096 bytes or less"
        throw XcdError.subprocess(invocation, out, code: .simulatorFailed, message: "the push to \(bundleId) failed", next: next)
    }

    public func privacy(udid: String, action: PrivacyAction, service: String, bundleId: String?) async throws {
        let invocation = simctl(["privacy", udid, action.rawValue, service] + (bundleId.map { [$0] } ?? []))
        let out = try await runner.run(invocation)
        guard !out.succeeded else { return }
        throw XcdError.subprocess(invocation, out, code: .simulatorFailed,
                                  message: "simctl could not \(action.rawValue) \(service)",
                                  next: "simctl's documented services: " + Self.privacyServices.joined(separator: ", ")
                                      + "; some unlisted ones, such as camera, also work")
    }

    public func overrideStatusBar(udid: String, _ overrides: StatusBarOverrides) async throws {
        try await runner.runChecked(simctl(["status_bar", udid, "override"] + overrides.arguments()),
                                    code: .simulatorFailed, next: "run `xcd doctor`")
    }

    public func clearStatusBar(udid: String) async throws {
        try await runner.runChecked(simctl(["status_bar", udid, "clear"]), code: .simulatorFailed, next: "run `xcd doctor`")
    }

    public func setAppearance(udid: String, _ appearance: Appearance) async throws {
        try await runner.runChecked(simctl(["ui", udid, "appearance", appearance.rawValue]),
                                    code: .simulatorFailed, next: "run `xcd doctor`")
    }

    /// Nil clears the simulated location.
    public func setLocation(udid: String, _ coordinate: Coordinate?) async throws {
        let args = coordinate.map { ["location", udid, "set", $0.text] } ?? ["location", udid, "clear"]
        try await runner.runChecked(simctl(args), code: .simulatorFailed, next: "run `xcd doctor`")
    }

    /// Sets the pasteboard to the text in `file` (simctl reads it from stdin).
    public func copyText(udid: String, file: String) async throws {
        var invocation = simctl(["pbcopy", udid])
        invocation.inputFile = file
        try await runner.runChecked(invocation, code: .simulatorFailed, next: "run `xcd doctor`")
    }

    /// The pasteboard's text, exactly (no newline is added or removed).
    public func pasteText(udid: String) async throws -> String {
        try await runner.runChecked(simctl(["pbpaste", udid]), code: .simulatorFailed, next: "run `xcd doctor`").stdoutString
    }

    /// Callers check that each file exists first: simctl crashes on a missing one.
    public func addMedia(udid: String, files: [String]) async throws {
        // The first import on a fresh clone starts the Photos library, which can take well over a minute.
        try await runner.runChecked(simctl(["addmedia", udid] + files, timeout: .seconds(180)), code: .simulatorFailed,
                                    next: "add photos (png, jpg, heic) or videos (mov, mp4) that exist")
    }

    /// Writes a PNG of the main display to `path`, whose folder must exist.
    public func screenshot(udid: String, path: String) async throws {
        try await runner.runChecked(simctl(["io", udid, "screenshot", path]), code: .simulatorFailed, next: "run `xcd doctor`")
    }

    /// Records the main display until SIGINT, then finishes the file (SIGTERM leaves it empty).
    public func recordVideoInvocation(udid: String, path: String) -> Invocation {
        simctl(["io", udid, "recordVideo", "--codec=h264", path])
    }
}
