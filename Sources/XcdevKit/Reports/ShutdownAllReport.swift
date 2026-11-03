import Foundation

/// What `xcd sim shutdown --all` did to each simulator device of the worktree.
public struct ShutdownAllReport: Reportable {
    public struct Device: Codable, Sendable, Equatable {
        public let device: String
        public let udid: String?
        /// "shut down", "not booted", or "not cloned".
        public let action: String
        public let retries: Int
        public let notes: [String]

        public init(device: String, udid: String?, action: String, retries: Int, notes: [String]) {
            self.device = device
            self.udid = udid
            self.action = action
            self.retries = retries
            self.notes = notes
        }
    }

    public let devices: [Device]
    public let worktree: String

    public init(devices: [Device], worktree: String) {
        self.devices = devices
        self.worktree = worktree
    }

    public var text: String {
        guard devices.contains(where: { $0.action == "shut down" }) else { return "nothing booted in \(worktree)" }
        return devices.flatMap(lines).joined(separator: "\n")
    }

    private func lines(_ device: Device) -> [String] {
        let head = device.action == "shut down"
            ? "shut down \(device.device)  udid=\(device.udid ?? "")" + (device.retries > 0 ? "  retries=\(device.retries)" : "")
            : "\(device.device): \(device.action)"
        return [head] + device.notes
    }

    public var envelopeWorktree: String? { worktree }
}

/// What `xcd sim shutdown` did: one clone's report, or with --all every clone's. It prints and encodes as the report it
/// holds, so the command has one result type for both.
public enum ShutdownResult: Reportable {
    case one(SimReport)
    case all(ShutdownAllReport)

    private var report: any Reportable {
        switch self {
        case .one(let report): return report
        case .all(let report): return report
        }
    }

    public func encode(to encoder: any Encoder) throws { try report.encode(to: encoder) }
    public var text: String { report.text }
    public var envelopeWorktree: String? { report.envelopeWorktree }
    public var failure: XcdError? { report.failure }
    public var textIsData: Bool { report.textIsData }
}

/// Which clones `xcd sim shutdown` acts on.
public enum ShutdownScope: Equatable, Sendable {
    case one(String?), all

    public static func parse(all: Bool, device: String?) throws -> ShutdownScope {
        if all, device != nil {
            throw XcdError(.usage, "--all and --device can't be combined", next: "pass one of them")
        }
        return all ? .all : .one(device)
    }
}
