import Foundation

public enum AppRunState: String, Codable, Sendable {
    case foreground, background
    case notRunning = "not_running"
}

/// What the engine needs from the device. The runner implements it with XCUITest; unit tests with a fake.
public protocol DeviceDriving: AnyObject {
    func appState(_ bundleId: String) -> AppRunState
    func appSnapshot(_ bundleId: String) throws -> SnapshotNode
    func systemSnapshot() throws -> SnapshotNode
    /// The system alert on screen, if any.
    func systemAlert() -> SnapshotNode?
    var scale: Double { get }
    var orientation: String { get }
    /// Taps a point in screen points.
    func tap(x: Double, y: Double) throws
    func pause(_ seconds: Double)
    /// Seconds from any fixed origin.
    func now() -> Double
}

/// Handles the runner's requests. One instance lives for the runner's life and holds the ref table.
public final class RunnerEngine {
    let device: DeviceDriving
    /// Refs of the last tree returned.
    public private(set) var refs: [String: RefSignature] = [:]
    /// Seconds between polls while looking for an element.
    static let pollInterval = 0.1
    public var runnerBundleId = ""
    public var rolesVerified = true

    public init(device: DeviceDriving) {
        self.device = device
    }

    struct Scene {
        var nodes: [FlatNode]
        var screen: ScreenRect
        var state: String
    }

    /// The target app's elements plus any system alert, or Springboard when the app isn't in front or `system` is set.
    func readScene(bundleId: String?, system: Bool) throws -> Scene {
        var nodes: [FlatNode] = []
        var state = "system"
        if !system, let bundleId {
            let appState = device.appState(bundleId)
            state = appState.rawValue
            if appState == .foreground {
                TreeBuilder.flatten(try device.appSnapshot(bundleId), source: .app, into: &nodes)
                if let alert = device.systemAlert() { TreeBuilder.flatten(alert, source: .system, into: &nodes) }
                return Scene(nodes: nodes, screen: nodes[0].frame, state: state)
            }
        }
        TreeBuilder.flatten(try device.systemSnapshot(), source: .system, into: &nodes)
        return Scene(nodes: nodes, screen: nodes[0].frame, state: state)
    }

    /// Gives the displayed elements fresh refs and replaces the ref table.
    func elements(of scene: Scene, all: Bool) -> [TreeElement] {
        var table: [String: RefSignature] = [:]
        let shown = TreeBuilder.displayed(scene.nodes, screen: scene.screen, all: all)
        let elements = shown.enumerated().map { number, index -> TreeElement in
            let ref = "e\(number + 1)"
            table[ref] = scene.nodes[index].signature
            return TreeBuilder.element(scene.nodes[index], ref: ref, screen: scene.screen)
        }
        refs = table
        return elements
    }

    func seen(_ scene: Scene) -> [String] {
        var names: [String] = []
        for index in TreeBuilder.displayed(scene.nodes, screen: scene.screen, all: false) {
            let node = scene.nodes[index]
            for name in [node.label, node.identifier] where !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return Array(names.prefix(60))
    }

    public func tree(_ request: TreeRequest) -> Result<TreeResult, RunnerFailure> {
        do {
            let scene = try readScene(bundleId: request.bundleId, system: request.system)
            return .success(TreeResult(bundleId: request.bundleId, state: scene.state, screen: scene.screen, scale: device.scale,
                                       orientation: device.orientation, keyboard: scene.nodes.contains { $0.role == "keyboard" },
                                       elements: elements(of: scene, all: request.all)))
        } catch {
            return .failure(RunnerFailure(code: RunnerFailure.Code.internal, message: "could not read the screen: \(error)"))
        }
    }

    public func tap(_ request: TargetRequest) -> Result<ActionResult, RunnerFailure> {
        let start = device.now()
        func ms() -> Int { Int((device.now() - start) * 1000) }
        do {
            if case .point(let x, let y) = request.target {
                try device.tap(x: x, y: y)
                return .success(ActionResult(element: nil, x: x, y: y, ms: ms()))
            }
            var last = RunnerFailure(code: RunnerFailure.Code.notFound, message: "no element matches")
            while true {
                let scene = try readScene(bundleId: request.bundleId, system: request.system)
                switch TargetMatcher.match(request.target, role: request.role, index: request.index, in: scene.nodes, refs: refs) {
                case .staleRef:
                    return .failure(RunnerFailure(code: RunnerFailure.Code.staleRef, message: "that ref no longer names one element on screen"))
                case .ambiguous(let found):
                    let shown = elements(of: scene, all: false)
                    let candidates = found.map { index -> TreeElement in
                        shown.first { $0.frame == scene.nodes[index].frame && $0.role == scene.nodes[index].role && $0.label == scene.nodes[index].label }
                            ?? TreeBuilder.element(scene.nodes[index], ref: nil, screen: scene.screen)
                    }
                    return .failure(RunnerFailure(code: RunnerFailure.Code.ambiguous, message: "\(found.count) elements match", candidates: candidates))
                case .one(let index):
                    let node = scene.nodes[index]
                    if !node.enabled {
                        last = RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the element is disabled", frame: node.frame)
                    } else if !TreeBuilder.isOnScreen(node, screen: scene.screen) {
                        last = RunnerFailure(code: RunnerFailure.Code.notHittable, message: "the element is off screen", frame: node.frame)
                    } else {
                        try device.tap(x: node.frame.midX, y: node.frame.midY)
                        return .success(ActionResult(element: TreeBuilder.element(node, ref: nil, screen: scene.screen),
                                                     x: node.frame.midX, y: node.frame.midY, ms: ms()))
                    }
                case .none:
                    last = RunnerFailure(code: RunnerFailure.Code.notFound, message: "no element matches", seen: seen(scene))
                }
                guard device.now() - start + Self.pollInterval <= request.timeout else { return .failure(last) }
                device.pause(Self.pollInterval)
            }
        } catch {
            return .failure(RunnerFailure(code: RunnerFailure.Code.internal, message: "the tap failed: \(error)"))
        }
    }

    public func wait(_ request: TargetRequest) -> Result<ActionResult, RunnerFailure> {
        let start = device.now()
        do {
            while true {
                let scene = try readScene(bundleId: request.bundleId, system: request.system)
                var present: Int?
                var anyPresent = false
                switch TargetMatcher.match(request.target, role: request.role, index: request.index, in: scene.nodes, refs: refs) {
                case .one(let index):
                    if TreeBuilder.isOnScreen(scene.nodes[index], screen: scene.screen) {
                        present = index
                        anyPresent = true
                    }
                case .ambiguous(let found):
                    present = found.first { TreeBuilder.isOnScreen(scene.nodes[$0], screen: scene.screen) }
                    anyPresent = present != nil
                case .staleRef:
                    if !request.gone {
                        return .failure(RunnerFailure(code: RunnerFailure.Code.staleRef, message: "that ref no longer names one element on screen"))
                    }
                case .none:
                    break
                }
                let ms = Int((device.now() - start) * 1000)
                if request.gone, !anyPresent { return .success(ActionResult(element: nil, x: nil, y: nil, ms: ms)) }
                if !request.gone, let present {
                    return .success(ActionResult(element: TreeBuilder.element(scene.nodes[present], ref: nil, screen: scene.screen),
                                                 x: nil, y: nil, ms: ms))
                }
                guard device.now() - start + Self.pollInterval <= request.timeout else {
                    return .failure(RunnerFailure(code: RunnerFailure.Code.waitTimeout,
                                                  message: request.gone ? "the element is still on screen" : "the element did not appear",
                                                  seen: seen(scene)))
                }
                device.pause(Self.pollInterval)
            }
        } catch {
            return .failure(RunnerFailure(code: RunnerFailure.Code.internal, message: "the wait failed: \(error)"))
        }
    }

    /// One HTTP request in, one JSON reply out. Never throws: a request the engine can't read is a `bad_request` reply.
    public func handle(path: String, body: Data) -> Data {
        func reply<Payload: Codable>(_ outcome: Result<Payload, RunnerFailure>) -> Data {
            (try? JSONEncoder().encode(RunnerReply(outcome))) ?? Data(#"{"ok":false}"#.utf8)
        }
        func decoded<Request: Decodable>(_ type: Request.Type) -> Result<Request, RunnerFailure> {
            do {
                return .success(try JSONDecoder().decode(type, from: body))
            } catch {
                return .failure(RunnerFailure(code: RunnerFailure.Code.badRequest, message: "the request body is not a valid \(type): \(error)"))
            }
        }
        switch path {
        case RunnerProtocol.healthPath:
            return reply(Result<HealthInfo, RunnerFailure>.success(
                HealthInfo(protocolVersion: RunnerProtocol.version, runner: runnerBundleId, rolesVerified: rolesVerified)))
        case RunnerProtocol.treePath:
            return reply(decoded(TreeRequest.self).flatMap(tree))
        case RunnerProtocol.tapPath:
            return reply(decoded(TargetRequest.self).flatMap(tap))
        case RunnerProtocol.waitPath:
            return reply(decoded(TargetRequest.self).flatMap(wait))
        default:
            return reply(Result<HealthInfo, RunnerFailure>.failure(
                RunnerFailure(code: RunnerFailure.Code.badRequest, message: "unknown path \(path)")))
        }
    }
}
