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
    /// Presses a point for `duration` seconds.
    func press(x: Double, y: Double, duration: Double) throws
    /// Drags from one point to another over `duration` seconds.
    func drag(from: ScreenPoint, to: ScreenPoint, duration: Double) throws
    /// Types into whatever has keyboard focus.
    func typeText(_ text: String) throws
    /// Presses one key as a hardware keyboard would; with `command`, while holding Command.
    func pressKey(_ key: String, command: Bool) throws
    /// Puts text on the device's pasteboard.
    func setPasteboard(text: String)
    /// Puts an image file's contents on the device's pasteboard. False when the data is not an image.
    func setPasteboard(image: Data) -> Bool
    /// Presses a hardware button. False when this device has no such button.
    func pressButton(_ button: HardwareButton) throws -> Bool
    /// Turns the device to an orientation.
    func rotate(to orientation: DeviceOrientation) throws
    func pause(_ seconds: Double)
    /// Seconds from any fixed origin.
    func now() -> Double
}

/// Handles the runner's requests. One instance lives for the runner's life and holds the ref table.
public final class RunnerEngine {
    let device: DeviceDriving
    /// Refs of the last tree returned, and of the candidates an ambiguous target listed since.
    public private(set) var refs: [String: RefSignature] = [:]
    /// The number of the last ref given out. A number is never given to a second element, so a ref from an earlier
    /// tree either still names its element or is in no table.
    private var lastRef = 0
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

    /// The part of the screen the keyboard covers, with the bars above and below its keys; nil when no keyboard is up.
    func keyboardArea(in scene: Scene) -> ScreenRect? {
        TreeBuilder.keyboardContainer(in: scene.nodes, screen: scene.screen).map { scene.nodes[$0].frame }
    }

    /// Why a tap on `scene.nodes[index]` would not reach it: a system alert is up, or the keyboard is over it. Only app
    /// elements can be covered. A system alert is modal, so it covers every app element, not only those under its
    /// frame. A bar the app put above the keyboard is in the keyboard's area, but nothing is over it.
    func coveredBy(_ index: Int, in scene: Scene) -> String? {
        let node = scene.nodes[index]
        guard node.source == .app else { return nil }
        if scene.alert != nil { return "the element is covered by a system alert" }
        if !node.inKeyboard, node.role != "keyboard", let keyboard = keyboardArea(in: scene),
           keyboard.contains(x: node.frame.midX, y: node.frame.midY),
           !TreeBuilder.isInAccessoryBar(index, in: scene.nodes, screen: scene.screen) {
            return "the element is covered by the keyboard"
        }
        return nil
    }

    /// Why `scene.nodes[index]` can't be tapped now, if it can't.
    func unhittable(_ index: Int, in scene: Scene) -> String? {
        let node = scene.nodes[index]
        if !node.enabled { return "the element is disabled" }
        if node.frame.isEmpty { return "the element has no size" }
        if !TreeBuilder.isOnScreen(node, screen: scene.screen) { return "the element is off screen" }
        return coveredBy(index, in: scene)
    }

    /// Seconds to keep looking: at most two minutes, so a runner can't be held for hours.
    static func clamped(_ timeout: Double) -> Double {
        timeout.isNaN ? 0 : min(max(timeout, 0), 120)
    }

    /// The elements at `indices`, each with its ref, and the table of those refs. An element that is in the ref
    /// table keeps the ref it has there; any other gets the next number.
    func withRefs(_ indices: [Int], in scene: Scene) -> (elements: [TreeElement], table: [String: RefSignature]) {
        var known: [RefSignature: String] = [:]
        for (ref, signature) in refs { known[signature] = ref }
        var table: [String: RefSignature] = [:]
        let elements = indices.map { index -> TreeElement in
            let signature = scene.nodes[index].signature
            // Taken out, so that a second element with the same signature can't get the same ref.
            let ref = known.removeValue(forKey: signature) ?? nextRef()
            table[ref] = signature
            return TreeBuilder.element(scene.nodes[index], ref: ref, screen: scene.screen)
        }
        return (elements, table)
    }

    func nextRef() -> String {
        lastRef += 1
        return "e\(lastRef)"
    }

    /// Gives the displayed elements their refs and replaces the ref table with them.
    func elements(of scene: Scene, all: Bool) -> [TreeElement] {
        let listed = withRefs(TreeBuilder.displayed(scene.nodes, screen: scene.screen, all: all), in: scene)
        refs = listed.table
        return listed.elements
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
                                       orientation: device.orientation, keyboard: keyboardArea(in: scene) != nil,
                                       elements: elements(of: scene, all: request.all)))
        } catch {
            return .failure(RunnerFailure(code: RunnerFailure.Code.internal, message: "could not read the screen: \(error)"))
        }
    }

    /// What one look at the screen decided for a tap or a wait.
    enum Attempt {
        case done(Result<ActionResult, RunnerFailure>)
        /// Not yet: look again until the timeout, then this is the answer.
        case retry(RunnerFailure)
    }

    /// Looks at the screen every `pollInterval` until `attempt` settles or the scope's timeout passes; the last look's
    /// failure is then the answer. A snapshot that throws is one failed look, not the end: the screen may be changing,
    /// and what the last look that worked said is a better answer than the snapshot's error.
    func poll(_ scope: ActionScope, what: String, attempt: (Scene, _ elapsedMs: () -> Int) -> Attempt) -> Result<ActionResult, RunnerFailure> {
        let start = device.now()
        let timeout = Self.clamped(scope.timeout)
        let elapsedMs = { Int((self.device.now() - start) * 1000) }
        var answer: RunnerFailure?
        while true {
            let outcome: Attempt
            do {
                outcome = attempt(try readScene(bundleId: scope.bundleId, system: scope.system, forAction: true), elapsedMs)
            } catch {
                outcome = .retry(answer ?? RunnerFailure(code: RunnerFailure.Code.internal, message: "the \(what) failed: \(error)"))
            }
            switch outcome {
            case .done(let result):
                return result
            case .retry(let failure):
                answer = failure
                guard device.now() - start + Self.pollInterval <= timeout else { return .failure(failure) }
            }
            device.pause(Self.pollInterval)
        }
    }

    /// What a ref that is in no table is told. xcd reads these words to say what to do next.
    public static let unknownRef = "that ref is not in the latest tree"

    /// The failure for a ref that does not name one element now. Its element is gone or no longer unique; or the ref
    /// is not in the table at all: the latest tree does not list its element, or it was never given out.
    func staleRef(_ target: TargetSpec) -> RunnerFailure {
        if case .ref(let name) = target, refs[name] == nil {
            return RunnerFailure(code: RunnerFailure.Code.staleRef, message: Self.unknownRef)
        }
        return RunnerFailure(code: RunnerFailure.Code.staleRef, message: "that ref no longer names one element on screen")
    }

    /// The failure for several matches. Each candidate has a ref, so `ref:eN` can pick one: the ref it already has, or
    /// a new one that is added to the table.
    func ambiguous(_ found: [Int], in scene: Scene) -> RunnerFailure {
        let listed = withRefs(found, in: scene)
        refs.merge(listed.table) { _, new in new }
        return RunnerFailure(code: RunnerFailure.Code.ambiguous, message: "\(found.count) elements match", candidates: listed.elements)
    }

    public func wait(_ request: TargetRequest) -> Result<ActionResult, RunnerFailure> {
        if let refusal = refusal(request.scope) { return .failure(refusal) }
        if case .point = request.target {
            return .failure(RunnerFailure(code: RunnerFailure.Code.badRequest, message: "a point can't be waited for"))
        }
        return poll(request.scope, what: "wait") { scene, elapsedMs in self.waitAttempt(request, in: scene, elapsedMs: elapsedMs) }
    }

    func waitAttempt(_ request: TargetRequest, in scene: Scene, elapsedMs: () -> Int) -> Attempt {
        if scene.appAway { return .retry(appAwayFailure(scene)) }
        let present: Int?
        switch presence(of: request, in: scene) {
        case .failure(let failure): return .done(.failure(failure))
        case .success(let index): present = index
        }
        if request.gone, present == nil { return .done(.success(ActionResult(element: nil, x: nil, y: nil, ms: elapsedMs()))) }
        if !request.gone, let present {
            let element = TreeBuilder.element(scene.nodes[present], ref: nil, screen: scene.screen)
            return .done(.success(ActionResult(element: element, x: nil, y: nil, ms: elapsedMs())))
        }
        return .retry(RunnerFailure(code: RunnerFailure.Code.waitTimeout,
                                    message: request.gone ? "the element is still on screen" : "the element did not appear", seen: seen(scene)))
    }

    /// The index of the on-screen element the request waits for, nil when none is on screen; or why the wait can't go on.
    func presence(of request: TargetRequest, in scene: Scene) -> Result<Int?, RunnerFailure> {
        switch TargetMatcher.match(request.target, role: request.role, index: request.index, in: scene.nodes, refs: refs) {
        case .one(let index):
            return .success(TreeBuilder.isOnScreen(scene.nodes[index], screen: scene.screen) ? index : nil)
        case .ambiguous(let found):
            return .success(found.first { TreeBuilder.isOnScreen(scene.nodes[$0], screen: scene.screen) })
        case .staleRef:
            // A ref that was never issued is unknown; one that was issued and no longer matches is gone.
            if case .ref(let name) = request.target, !request.gone || refs[name] == nil { return .failure(staleRef(request.target)) }
            return .success(nil)
        case .none:
            return .success(nil)
        }
    }
}
