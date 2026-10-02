import Foundation
import Synchronization
import XcdevKit

/// Simulates `xcrun simctl` on a FakeProcessRunner. Device types and runtimes come from a
/// `simctl list -j` fixture; devices live in memory and change with create/clone/delete/boot.
public final class FakeSimulators: Sendable {
    public struct Device: Sendable, Equatable {
        public var udid: String
        public var name: String
        public var typeIdentifier: String
        public var runtimeIdentifier: String
        public var state: String
        public var isAvailable = true
        /// Reported as `dataPath`; defaults to a path that doesn't exist (`/sims/<udid>/data`).
        public var dataPath: String?
        /// Reported as `dataPathSize`.
        public var dataPathSize: Int64 = 1_048_576
    }

    private struct State {
        var devices: [Device]
        var creates = 0
        var clones = 0
        var pairs: [[String]] = []
    }

    private let state: Mutex<State>
    private let baseCatalog: Data

    public init(runner: FakeProcessRunner, catalogJSON: String) throws {
        var object = try JSONSerialization.jsonObject(with: Data(catalogJSON.utf8)) as? [String: Any] ?? [:]
        var initial: [Device] = []
        for (runtime, list) in object["devices"] as? [String: [[String: Any]]] ?? [:] {
            for d in list {
                var device = Device(udid: d["udid"] as? String ?? UUID().uuidString,
                                    name: d["name"] as? String ?? "",
                                    typeIdentifier: d["deviceTypeIdentifier"] as? String ?? "",
                                    runtimeIdentifier: runtime,
                                    state: d["state"] as? String ?? "Shutdown")
                device.isAvailable = d["isAvailable"] as? Bool ?? true
                device.dataPath = d["dataPath"] as? String
                if let size = d["dataPathSize"] as? Int64 { device.dataPathSize = size }
                initial.append(device)
            }
        }
        object["devices"] = [String: Any]()
        baseCatalog = try JSONSerialization.data(withJSONObject: object)
        state = Mutex(State(devices: initial))
        install(on: runner)
    }

    public var devices: [Device] { state.withLock { $0.devices } }
    public var createCount: Int { state.withLock { $0.creates } }
    public var cloneCount: Int { state.withLock { $0.clones } }
    public var pairs: [[String]] { state.withLock { $0.pairs } }
    public func device(named name: String) -> Device? { devices.first { $0.name == name } }
    public func deleteExternally(udid: String) { state.withLock { $0.devices.removeAll { $0.udid == udid } } }

    /// Adds a device as if something outside xcd made it (another run, a crash, a user). Returns its udid.
    @discardableResult
    public func add(name: String, typeIdentifier: String = "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
                    runtimeIdentifier: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-0", state: String = "Shutdown",
                    isAvailable: Bool = true, dataPath: String? = nil) -> String {
        let udid = UUID().uuidString
        var device = Device(udid: udid, name: name, typeIdentifier: typeIdentifier, runtimeIdentifier: runtimeIdentifier,
                            state: state)
        device.isAvailable = isAvailable
        device.dataPath = dataPath
        self.state.withLock { $0.devices.append(device) }
        return udid
    }

    /// Sets a device's state, e.g. to leave it stuck in "Booting".
    public func setState(_ value: String, udid: String) {
        state.withLock { st in
            if let index = st.devices.firstIndex(where: { $0.udid == udid }) { st.devices[index].state = value }
        }
    }

    /// `xcodebuild -showsdks -json` for an Xcode whose simulator SDKs are all 27.0 (matches simctl-list.json).
    public static let sdksJSON = #"[{"platform":"iphonesimulator","sdkVersion":"27.0"},{"platform":"watchsimulator","sdkVersion":"27.0"},{"platform":"appletvsimulator","sdkVersion":"27.0"},{"platform":"xrsimulator","sdkVersion":"27.0"}]"#

    private func install(on runner: FakeProcessRunner) {
        runner.stub(["xcrun", "xcodebuild", "-showsdks", "-json"]) { _ in ProcessOutput(stdout: Self.sdksJSON) }
        runner.stub(["xcrun", "simctl", "list", "-j"]) { [self] _ in ProcessOutput(stdout: listJSON()) }

        runner.stub(["xcrun", "simctl", "create"]) { [self] inv in
            let a = inv.arguments                     // simctl create <name> <type> <runtime>
            let udid = UUID().uuidString
            state.withLock {
                $0.devices.append(Device(udid: udid, name: a[2], typeIdentifier: a[3], runtimeIdentifier: a[4], state: "Shutdown"))
                $0.creates += 1
            }
            return ProcessOutput(stdout: udid + "\n")
        }

        runner.stub(["xcrun", "simctl", "clone"]) { [self] inv in
            let a = inv.arguments                     // simctl clone <source> <name>
            return state.withLock { st in
                guard let source = st.devices.first(where: { $0.udid == a[2] }) else {
                    return ProcessOutput(exitCode: 148, stderr: "Invalid device: \(a[2])")
                }
                let udid = UUID().uuidString
                st.devices.append(Device(udid: udid, name: a[3], typeIdentifier: source.typeIdentifier,
                                         runtimeIdentifier: source.runtimeIdentifier, state: "Shutdown"))
                st.clones += 1
                return ProcessOutput(stdout: udid + "\n")
            }
        }

        runner.stub(["xcrun", "simctl", "delete"]) { [self] inv in
            let udid = inv.arguments[2]
            return state.withLock { st in
                guard st.devices.contains(where: { $0.udid == udid }) else {
                    return ProcessOutput(exitCode: 148, stderr: "Invalid device: \(udid)")
                }
                st.devices.removeAll { $0.udid == udid }
                return ProcessOutput()
            }
        }

        runner.stub(["xcrun", "simctl", "boot"]) { [self] inv in
            transition(inv.arguments[2], to: "Booted", verb: "boot")
        }
        runner.stub(["xcrun", "simctl", "shutdown"]) { [self] inv in
            transition(inv.arguments[2], to: "Shutdown", verb: "shutdown")
        }
        runner.stub(["xcrun", "simctl", "bootstatus"]) { _ in ProcessOutput() }
        runner.stub(["xcrun", "simctl", "erase"]) { _ in ProcessOutput() }
        runner.stub(["xcrun", "simctl", "pair"]) { [self] inv in
            state.withLock { $0.pairs.append([inv.arguments[2], inv.arguments[3]]) }
            return ProcessOutput(stdout: UUID().uuidString + "\n")
        }
        runner.stub(["open", "-a", "Simulator"]) { _ in ProcessOutput() }
    }

    private func transition(_ udid: String, to target: String, verb: String) -> ProcessOutput {
        state.withLock { st in
            guard let index = st.devices.firstIndex(where: { $0.udid == udid }) else {
                return ProcessOutput(exitCode: 148, stderr: "Invalid device: \(udid)")
            }
            if st.devices[index].state == target {
                return ProcessOutput(exitCode: 149, stderr: "Unable to \(verb) device in current state: \(target)")
            }
            st.devices[index].state = target
            return ProcessOutput()
        }
    }

    private func listJSON() -> String {
        var object = (try? JSONSerialization.jsonObject(with: baseCatalog) as? [String: Any]) ?? [:]
        var grouped: [String: [[String: Any]]] = [:]
        for d in devices {
            grouped[d.runtimeIdentifier, default: []].append([
                "udid": d.udid, "name": d.name, "state": d.state, "isAvailable": d.isAvailable,
                "deviceTypeIdentifier": d.typeIdentifier, "dataPath": d.dataPath ?? "/sims/\(d.udid)/data",
                "dataPathSize": d.dataPathSize,
            ])
        }
        object["devices"] = grouped
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
