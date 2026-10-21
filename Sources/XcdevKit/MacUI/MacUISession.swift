import Foundation

/// One `ui` request on a Mac: the engine runs here, over the driver, with the refs of the last command.
struct MacUISession {
    let device: String
    let pid: Int32
    let api: any AccessibilityAPI
    let refFile: String

    var session: RunnerSession { RunnerSession(device: device, udid: "pid \(pid)", port: 0, token: "", restarted: false) }

    /// The driver and the engine are made here and die here: the elements they hold never leave this call.
    func perform<Request: Encodable, Payload: Codable>(_ path: String, _ request: Request) throws -> Result<Payload, RunnerFailure> {
        let saved = MacRefStore.load(refFile)
        let driver = MacDriver(pid: pid, api: api)
        let engine = RunnerEngine(device: driver, refs: saved.refs, lastRef: saved.lastRef)
        engine.runnerBundleId = "mac"
        let body = engine.handle(path: path, body: try JSONEncoder().encode(request))
        try MacRefStore.save(MacRefs(refs: engine.refs, lastRef: engine.lastRefNumber), to: refFile)
        guard let reply = try? JSONDecoder().decode(RunnerReply<Payload>.self, from: body) else {
            throw XcdError(.runnerFailed, "the Mac driver gave a reply xcd could not read", next: "run `xcd ui stop`, then retry",
                           details: [String(decoding: body.prefix(400), as: UTF8.self)])
        }
        guard let result = reply.result, reply.ok else {
            return .failure(reply.failure ?? RunnerFailure(code: RunnerFailure.Code.internal, message: "the driver gave no result"))
        }
        return .success(Self.withScene(result, driver.lastScene))
    }

    /// The Mac's `hidden`, window title, window count, and cap on a tree result, and on an action's `--tree`; other
    /// payloads pass through.
    static func withScene<Payload>(_ payload: Payload, _ scene: MacScene?) -> Payload {
        guard let scene else { return payload }
        func stamped(_ tree: TreeResult) -> TreeResult {
            var tree = tree
            tree.hidden = scene.hidden
            tree.windowTitle = scene.mainTitle
            tree.windows = scene.windows.count
            tree.capped = scene.capped
            return tree
        }
        if let tree = payload as? TreeResult { return (stamped(tree) as? Payload) ?? payload }
        if var action = payload as? ActionResult, let tree = action.tree {
            action.tree = stamped(tree)
            return (action as? Payload) ?? payload
        }
        return payload
    }
}
