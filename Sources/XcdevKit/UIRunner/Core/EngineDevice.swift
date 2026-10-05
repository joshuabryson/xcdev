import Foundation

/// Actions on the device itself: hardware buttons, rotation, and the pasteboard.
extension RunnerEngine {
    func unknownName(_ request: DeviceRequest, _ kind: String, _ names: [String]) -> RunnerFailure {
        RunnerFailure(code: RunnerFailure.Code.badRequest, message: "'\(request.name)' is not \(kind); use one of: \(names.joined(separator: ", "))")
    }

    public func button(_ request: DeviceRequest) -> Result<ActionResult, RunnerFailure> {
        if let refusal = refusal(request.scope) { return .failure(refusal) }
        guard let button = HardwareButton(rawValue: request.name) else {
            return .failure(unknownName(request, "a button", HardwareButton.allCases.map(\.rawValue)))
        }
        var present = true
        let result = direct(request.scope, what: "button press") {
            present = try self.device.pressButton(button)
            if present, button == .home { self.waitForAppToLeave(request.scope) }
            return ActionResult(element: nil, x: nil, y: nil, ms: 0)
        }
        guard present else {
            return .failure(RunnerFailure(code: RunnerFailure.Code.unsupported, message: "this device has no \(button.rawValue) button"))
        }
        return result
    }

    /// Home sends the app in front to the background a moment after the press returns (seen: still in front
    /// 0.3 s later). Waits up to two seconds for that, so a tree read next shows where the device ended up.
    func waitForAppToLeave(_ scope: ActionScope) {
        guard !scope.system, let bundleId = scope.bundleId else { return }
        var waited = 0.0
        while device.appState(bundleId) == .foreground, waited < 2 {
            device.pause(Self.pollInterval)
            waited += Self.pollInterval
        }
    }

    public func rotate(_ request: DeviceRequest) -> Result<ActionResult, RunnerFailure> {
        if let refusal = refusal(request.scope) { return .failure(refusal) }
        guard let orientation = DeviceOrientation(rawValue: request.name) else {
            return .failure(unknownName(request, "an orientation", DeviceOrientation.allCases.map(\.rawValue)))
        }
        return direct(request.scope, what: "rotation") {
            try self.device.rotate(to: orientation)
            return ActionResult(element: nil, x: nil, y: nil, ms: 0)
        }
    }
}
