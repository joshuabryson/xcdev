import Foundation

/// What every action shares: where it may act, how it finds its element, and how it ends.
extension RunnerEngine {
    /// Seconds an action's effect gets to show before the tree is read for `--tree`.
    static let settle = 0.3

    /// An action must say where to act: an app, or the system. Without either it would act on the Home Screen.
    func refusal(_ scope: ActionScope) -> RunnerFailure? {
        guard !scope.system, scope.bundleId == nil else { return nil }
        return RunnerFailure(code: RunnerFailure.Code.badRequest, message: "the request names no app and is not for the system")
    }

    /// What one look for an action's element found.
    enum Lookup {
        case found(FlatNode)
        /// Not yet: look again until the timeout, then this is the answer.
        case retry(RunnerFailure)
        /// Looking again won't help.
        case stop(RunnerFailure)
    }

    func lookup(_ query: ElementQuery, in scene: Scene) -> Lookup {
        if scene.appAway { return .retry(appAwayFailure(scene)) }
        switch TargetMatcher.match(query.target, role: query.role, index: query.index, in: scene.nodes, refs: refs) {
        case .staleRef:
            return .stop(Self.staleRef)
        case .ambiguous(let found):
            return .stop(ambiguous(found, in: scene))
        case .none:
            return .retry(RunnerFailure(code: RunnerFailure.Code.notFound, message: "no element matches", seen: seen(scene)))
        case .one(let index):
            let node = scene.nodes[index]
            if let problem = unhittable(node, in: scene) {
                return .retry(RunnerFailure(code: RunnerFailure.Code.notHittable, message: problem, frame: node.frame))
            }
            return .found(node)
        }
    }

    /// Whether the scope's app is not running. Always false for the system, which has no app to lose.
    func appIsGone(_ scope: ActionScope) -> Bool {
        guard !scope.system, let bundleId = scope.bundleId else { return false }
        return device.appState(bundleId) == .notRunning
    }

    /// Ends an action that was carried out. If the app was running before and is gone now, the action ended it, and
    /// that is the result. Otherwise the tree is added when the scope asks for it.
    func finished(_ result: ActionResult, _ scope: ActionScope, what: String, appWasRunning: Bool) -> Result<ActionResult, RunnerFailure> {
        if appWasRunning, appIsGone(scope) {
            return .failure(RunnerFailure(code: RunnerFailure.Code.appCrashed, message: "the app is no longer running after the \(what)"))
        }
        guard scope.tree else { return .success(result) }
        var result = result
        result.tree = treeAfterAction(scope)
        return .success(result)
    }

    /// The tree once the action's effect has had `settle` seconds to show; nil if it can't be read in five tries.
    /// It replaces the ref table, like any tree.
    func treeAfterAction(_ scope: ActionScope) -> TreeResult? {
        let request = TreeRequest(bundleId: scope.bundleId, system: scope.system, all: false)
        for _ in 0..<5 {
            device.pause(Self.settle)
            if case .success(let tree) = tree(request) { return tree }
        }
        return nil
    }

    /// Runs a gesture once and stamps how long the action took. A gesture that throws is the action's failure and is
    /// never tried again: it may have happened. One that throws a `RunnerFailure` did nothing, and says why.
    func performed(_ what: String, _ elapsedMs: () -> Int, _ gesture: () throws -> ActionResult) -> Result<ActionResult, RunnerFailure> {
        do {
            var result = try gesture()
            result.ms = elapsedMs()
            return .success(result)
        } catch let refusal as RunnerFailure {
            return .failure(refusal)
        } catch {
            return .failure(RunnerFailure(code: RunnerFailure.Code.internal, message: "the \(what) failed: \(error)"))
        }
    }

    /// Finds the query's element within the scope's timeout, performs `gesture` on it once, and finishes the action.
    func onElement(_ query: ElementQuery, _ scope: ActionScope, what: String,
                   gesture: (FlatNode, Scene) throws -> ActionResult) -> Result<ActionResult, RunnerFailure> {
        let acted = poll(scope, what: what) { scene, elapsedMs in
            switch self.lookup(query, in: scene) {
            case .retry(let failure): return .retry(failure)
            case .stop(let failure): return .done(.failure(failure))
            case .found(let node): return .done(self.performed(what, elapsedMs) { try gesture(node, scene) })
            }
        }
        // The element was found in the app in front (or in the system), so the app was running.
        return acted.flatMap { finished($0, scope, what: what, appWasRunning: true) }
    }

    /// An action that looks nothing up (a point, a hardware button), so it happens whatever is on screen.
    func direct(_ scope: ActionScope, what: String, gesture: () throws -> ActionResult) -> Result<ActionResult, RunnerFailure> {
        let start = device.now()
        let wasRunning = !appIsGone(scope)
        return performed(what, { Int((self.device.now() - start) * 1000) }, gesture)
            .flatMap { finished($0, scope, what: what, appWasRunning: wasRunning) }
    }

    /// A tap or a long-press: at the point given, or at the centre of the element found.
    func press(_ request: TargetRequest, what: String, gesture: (ScreenPoint) throws -> Void) -> Result<ActionResult, RunnerFailure> {
        let scope = request.scope
        if let refusal = refusal(scope) { return .failure(refusal) }
        if case .point(let x, let y) = request.target {
            return direct(scope, what: what) {
                try gesture(ScreenPoint(x: x, y: y))
                return ActionResult(element: nil, x: x, y: y, ms: 0)
            }
        }
        return onElement(request.query, scope, what: what) { node, scene in
            try gesture(ScreenPoint(x: node.frame.midX, y: node.frame.midY))
            return ActionResult(element: TreeBuilder.element(node, ref: nil, screen: scene.screen), x: node.frame.midX, y: node.frame.midY, ms: 0)
        }
    }

    public func tap(_ request: TargetRequest) -> Result<ActionResult, RunnerFailure> {
        press(request, what: "tap") { try self.device.tap(x: $0.x, y: $0.y) }
    }

    /// Seconds a long-press holds when the request doesn't say.
    static let defaultPress = 1.0

    public func longPress(_ request: TargetRequest) -> Result<ActionResult, RunnerFailure> {
        let seconds = request.duration ?? Self.defaultPress
        // Held for at most a minute, so a runner can't be kept busy for hours.
        let duration = seconds.isNaN ? Self.defaultPress : min(max(seconds, 0.1), 60)
        return press(request, what: "long-press") { try self.device.press(x: $0.x, y: $0.y, duration: duration) }
    }
}
