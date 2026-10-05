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
        // A button the device lacks ends the action here: nothing was pressed, so no tree is read afterwards.
        return direct(request.scope, what: "button press") {
            guard try self.device.pressButton(button) else {
                throw RunnerFailure(code: RunnerFailure.Code.unsupported, message: "this device has no \(button.rawValue) button")
            }
            if button == .home { self.waitForAppToLeave(request.scope) }
            return ActionResult(element: nil, x: nil, y: nil, ms: 0)
        }
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

    public func pasteboard(_ request: PasteboardRequest) -> Result<PasteboardResult, RunnerFailure> {
        guard device.setPasteboard(image: request.image) else {
            return .failure(RunnerFailure(code: RunnerFailure.Code.badRequest, message: PasteboardRequest.notAnImage))
        }
        return .success(PasteboardResult(hasImages: true))
    }
}
