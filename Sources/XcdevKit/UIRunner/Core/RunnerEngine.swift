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
        /// Index of the system alert's root in `nodes`, if one is up.
        var alert: Int?
        /// Whether the target app was not in front, so an action has nothing to act on.
        var appAway = false
    }

    /// The target app's elements plus any system alert. When the app isn't in front, or `system` is set, Springboard instead,
    /// except for an action (`forAction`) on an app, whose scene is then empty: an action must never land on the Home Screen.
    func readScene(bundleId: String?, system: Bool, forAction: Bool = false) throws -> Scene {
        var nodes: [FlatNode] = []
        var state = "system"
        if !system, let bundleId {
            let appState = device.appState(bundleId)
            state = appState.rawValue
            if appState == .foreground {
                TreeBuilder.flatten(try device.appSnapshot(bundleId), source: .app, into: &nodes)
                var alertIndex: Int?
                if let alert = device.systemAlert() {
                    alertIndex = nodes.count
                    TreeBuilder.flatten(alert, source: .system, into: &nodes)
                }
                return Scene(nodes: nodes, screen: nodes[0].frame, state: state, alert: alertIndex)
            }
            if forAction {
                return Scene(nodes: [], screen: ScreenRect(x: 0, y: 0, w: 0, h: 0), state: state, alert: nil, appAway: true)
            }
        }
        TreeBuilder.flatten(try device.systemSnapshot(), source: .system, into: &nodes)
        return Scene(nodes: nodes, screen: nodes[0].frame, state: state, alert: nil)
    }

    func appAwayFailure(_ scene: Scene) -> RunnerFailure {
        let what = scene.state == AppRunState.background.rawValue ? "the app is in the background" : "the app is not running"
        return RunnerFailure(code: RunnerFailure.Code.appNotForeground, message: what)
    }

    /// Why a tap on `node` would not reach it: it is covered by a system alert or the keyboard. Only app elements can be covered.
    func coveredBy(_ node: FlatNode, in scene: Scene) -> String? {
        guard node.source == .app else { return nil }
        if let alert = scene.alert, scene.nodes[alert].frame.contains(x: node.frame.midX, y: node.frame.midY) {
            return "the element is covered by a system alert"
        }
        if !node.inKeyboard, node.role != "keyboard",
           let keyboard = scene.nodes.first(where: { $0.role == "keyboard" && TreeBuilder.isOnScreen($0, screen: scene.screen) }),
           keyboard.frame.contains(x: node.frame.midX, y: node.frame.midY) {
            return "the element is covered by the keyboard"
        }
        return nil
    }

    /// Seconds to keep looking: at most two minutes, so a runner can't be held for hours.
    static func clamped(_ timeout: Double) -> Double {
        timeout.isNaN ? 0 : min(max(timeout, 0), 120)
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
        let timeout = Self.clamped(request.timeout)
        func ms() -> Int { Int((device.now() - start) * 1000) }
        do {
            if case .point(let x, let y) = request.target {
                try device.tap(x: x, y: y)
                return .success(ActionResult(element: nil, x: x, y: y, ms: ms()))
            }
            var last = RunnerFailure(code: RunnerFailure.Code.notFound, message: "no element matches")
            while true {
                let scene = try readScene(bundleId: request.bundleId, system: request.system, forAction: true)
                if scene.appAway {
                    last = appAwayFailure(scene)
                } else {
                    switch TargetMatcher.match(request.target, role: request.role, index: request.index, in: scene.nodes, refs: refs) {
                    case .staleRef:
                        return .failure(RunnerFailure(code: RunnerFailure.Code.staleRef, message: "that ref no longer names one element on screen"))
                    case .ambiguous(let found):
                        // The refs become exactly the candidates, each with its own, so `ref:eN` can pick one.
                        var table: [String: RefSignature] = [:]
                        var candidates: [TreeElement] = []
                        for (number, index) in found.enumerated() {
                            let ref = "e\(number + 1)"
                            table[ref] = scene.nodes[index].signature
                            candidates.append(TreeBuilder.element(scene.nodes[index], ref: ref, screen: scene.screen))
                        }
                        refs = table
                        return .failure(RunnerFailure(code: RunnerFailure.Code.ambiguous, message: "\(found.count) elements match", candidates: candidates))
                    case .one(let index):
                        let node = scene.nodes[index]
                        let problem: String?
                        if !node.enabled {
                            problem = "the element is disabled"
                        } else if node.frame.isEmpty {
                            problem = "the element has no size"
                        } else if !TreeBuilder.isOnScreen(node, screen: scene.screen) {
                            problem = "the element is off screen"
                        } else {
                            problem = coveredBy(node, in: scene)
                        }
                        if let problem {
                            last = RunnerFailure(code: RunnerFailure.Code.notHittable, message: problem, frame: node.frame)
                        } else {
                            try device.tap(x: node.frame.midX, y: node.frame.midY)
                            return .success(ActionResult(element: TreeBuilder.element(node, ref: nil, screen: scene.screen),
                                                         x: node.frame.midX, y: node.frame.midY, ms: ms()))
                        }
                    case .none:
                        last = RunnerFailure(code: RunnerFailure.Code.notFound, message: "no element matches", seen: seen(scene))
                    }
                }
                guard device.now() - start + Self.pollInterval <= timeout else { return .failure(last) }
                device.pause(Self.pollInterval)
            }
        } catch {
            return .failure(RunnerFailure(code: RunnerFailure.Code.internal, message: "the tap failed: \(error)"))
        }
    }

    public func wait(_ request: TargetRequest) -> Result<ActionResult, RunnerFailure> {
        if case .point = request.target {
            return .failure(RunnerFailure(code: RunnerFailure.Code.badRequest, message: "a point can't be waited for"))
        }
        let start = device.now()
        let timeout = Self.clamped(request.timeout)
        do {
            while true {
                let scene = try readScene(bundleId: request.bundleId, system: request.system, forAction: true)
                var present: Int?
                if !scene.appAway {
                    switch TargetMatcher.match(request.target, role: request.role, index: request.index, in: scene.nodes, refs: refs) {
                    case .one(let index):
                        if TreeBuilder.isOnScreen(scene.nodes[index], screen: scene.screen) { present = index }
                    case .ambiguous(let found):
                        present = found.first { TreeBuilder.isOnScreen(scene.nodes[$0], screen: scene.screen) }
                    case .staleRef:
                        // A ref that was never issued is unknown; one that was issued and no longer matches is gone.
                        if case .ref(let name) = request.target, !request.gone || refs[name] == nil {
                            return .failure(RunnerFailure(code: RunnerFailure.Code.staleRef, message: "that ref no longer names one element on screen"))
                        }
                    case .none:
                        break
                    }
                    let ms = Int((device.now() - start) * 1000)
                    if request.gone, present == nil { return .success(ActionResult(element: nil, x: nil, y: nil, ms: ms)) }
                    if !request.gone, let present {
                        return .success(ActionResult(element: TreeBuilder.element(scene.nodes[present], ref: nil, screen: scene.screen),
                                                     x: nil, y: nil, ms: ms))
                    }
                }
                guard device.now() - start + Self.pollInterval <= timeout else {
                    if scene.appAway { return .failure(appAwayFailure(scene)) }
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

    /// The last-resort reply when even a plain failure can't be encoded.
    static let encodeFallback = #"{"ok":false,"failure":{"code":"internal","message":"could not encode the reply","candidates":[],"seen":[],"issues":[]}}"#

    /// One HTTP request in, one JSON reply out. Never throws: a request the engine can't read is a `bad_request` reply.
    public func handle(path: String, body: Data) -> Data {
        func reply<Payload: Codable>(_ outcome: Result<Payload, RunnerFailure>) -> Data {
            do {
                return try JSONEncoder().encode(RunnerReply(outcome))
            } catch {
                // A plain failure carries no frames or numbers, so it cannot fail the same way.
                let failure = RunnerFailure(code: RunnerFailure.Code.internal, message: "could not encode the reply: \(error)")
                return (try? JSONEncoder().encode(RunnerReply<HealthInfo>(.failure(failure)))) ?? Data(Self.encodeFallback.utf8)
            }
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
