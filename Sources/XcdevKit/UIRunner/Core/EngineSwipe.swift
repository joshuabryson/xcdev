import Foundation

extension RunnerEngine {
    /// Seconds a swipe takes.
    static let swipeSeconds = 0.3
    /// How far a direction swipe goes from the centre: this share of the element's extent along the swipe's axis.
    static let swipeShare = 0.4

    public func swipe(_ request: SwipeRequest) -> Result<ActionResult, RunnerFailure> {
        let scope = request.scope
        if let refusal = refusal(scope) { return .failure(refusal) }
        if let from = request.from, let to = request.to, request.direction == nil, request.on == nil {
            return direct(scope, what: "swipe") { try self.swiped(nil, from: from, to: to) }
        }
        guard let direction = request.direction, request.from == nil, request.to == nil else {
            return .failure(RunnerFailure(code: RunnerFailure.Code.badRequest,
                                          message: "a swipe takes a direction, or a from point and a to point, not both"))
        }
        guard let query = request.on else { return swipeScreen(direction, scope) }
        return onElement(query, scope, what: "swipe") { node, scene in
            try self.swiped(TreeBuilder.element(node, ref: nil, screen: scene.screen),
                            from: ScreenPoint(x: node.frame.midX, y: node.frame.midY), to: Self.end(of: direction, in: node.frame))
        }
    }

    /// A direction swipe with no element: across the screen, once the app is in front.
    func swipeScreen(_ direction: SwipeDirection, _ scope: ActionScope) -> Result<ActionResult, RunnerFailure> {
        let acted = poll(scope, what: "swipe") { scene, elapsedMs in
            if scene.appAway { return .retry(self.appAwayFailure(scene)) }
            return .done(self.performed("swipe", elapsedMs) {
                try self.swiped(nil, from: ScreenPoint(x: scene.screen.midX, y: scene.screen.midY), to: Self.end(of: direction, in: scene.screen))
            })
        }
        return acted.flatMap { finished($0, scope, what: "swipe", appWasRunning: true) }
    }

    func swiped(_ element: TreeElement?, from: ScreenPoint, to: ScreenPoint) throws -> ActionResult {
        try device.drag(from: from, to: to, duration: Self.swipeSeconds)
        var result = ActionResult(element: element, x: from.x, y: from.y, ms: 0)
        result.toX = to.x
        result.toY = to.y
        return result
    }

    /// Where a swipe from the centre of `frame` ends.
    static func end(of direction: SwipeDirection, in frame: ScreenRect) -> ScreenPoint {
        switch direction {
        case .up: return ScreenPoint(x: frame.midX, y: frame.midY - frame.h * swipeShare)
        case .down: return ScreenPoint(x: frame.midX, y: frame.midY + frame.h * swipeShare)
        case .left: return ScreenPoint(x: frame.midX - frame.w * swipeShare, y: frame.midY)
        case .right: return ScreenPoint(x: frame.midX + frame.w * swipeShare, y: frame.midY)
        }
    }
}
