import Foundation

/// One action for the runner, and what its errors call it and the thing it acts on.
struct ActionCall<Request: Encodable> {
    let path: String
    let request: Request
    /// "tap", "swipe", "typing", …
    let what: String
    /// The target as the user gave it, or what stands in for one ("the screen").
    let target: String
    var slack: Duration = .seconds(30)
}

/// An action the runner carried out, ready to be reported.
struct ActionDone {
    let result: ActionResult
    let session: RunnerSession
    let worktree: String
    let treeAsked: Bool

    func report(_ action: String, target: String, detail: String? = nil) -> UIActionReport {
        var report = UIActionReport(action: action, target: target, element: result.element, x: result.x, y: result.y, ms: result.ms,
                                    restarted: session.restarted, device: session.device, udid: session.udid, worktree: worktree)
        report.toX = result.toX
        report.toY = result.toY
        report.method = result.method
        report.detail = detail
        report.tree = result.tree
        if treeAsked, result.tree == nil { report.notes = [UIText.treeUnreadNote] }
        return report
    }
}

/// What `xcd ui swipe` was given: a direction (and maybe an element), or two points.
public struct SwipeOptions: Sendable {
    public var direction: String?
    public var on: String?
    public var from: String?
    public var to: String?

    public init(direction: String?, on: String?, from: String?, to: String?) {
        self.direction = direction
        self.on = on
        self.from = from
        self.to = to
    }
}

/// What `xcd ui type` was given besides the text.
public struct TypeOptions: Sendable {
    public var into: String?
    public var clear: Bool
    public var submit: Bool

    public init(into: String?, clear: Bool, submit: Bool) {
        self.into = into
        self.clear = clear
        self.submit = submit
    }
}

/// `xcd ui long-press`, `swipe`, `type`, `button`, and `rotate`, and what every action shares.
extension UIService {
    /// The longest text one `xcd ui type` takes: typing is slow, and the runner serves one request at a time.
    static let maxTypedCharacters = 2000

    /// Sends an action and returns what the runner did. An action is never sent twice. When the runner says the app is
    /// gone, the error carries the app's crash report if one was written.
    func act<Request: Encodable>(_ call: ActionCall<Request>, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> ActionDone {
        let started = now()
        let exchange = RunnerExchange(path: call.path, request: call.request, what: call.what, resend: false, slack: call.slack)
        let (session, result) = try await send(exchange, as: ActionResult.self, options, in: &ctx)
        switch result {
        case .success(let action):
            return ActionDone(result: action, session: session, worktree: ctx.state.name, treeAsked: options.tree)
        case .failure(let failure) where failure.code == RunnerFailure.Code.appCrashed:
            throw await crashed(during: call.what, since: started, options, in: ctx)
        case .failure(let failure):
            throw UIRunnerErrors.error(failure, target: call.target, timeout: options.effectiveTimeout)
        }
    }

    /// The error for an action that left the app no longer running. The report is looked for by the built app's
    /// process name, for up to three seconds: it is written a moment after the crash. Another `--bundle` has no name
    /// to look for. Only a report from this worktree's simulator counts: another worktree's clone can run the same app.
    /// On a Mac, only one from the Mac itself: a simulator's app can have the same name.
    func crashed(during what: String, since: Date, _ options: UIOptions, in ctx: WorktreeContext) async -> XcdError {
        let device = try? supervisor.provisioner.deviceName(options.device, config: ctx.config)
        let product = device.flatMap { try? RunService.product(for: $0, requested: nil, in: ctx) }
        let isMac = device.flatMap { ctx.config.allDevices[$0]?.isMac } ?? false
        let origin: CrashOrigin = isMac ? .mac : device.flatMap { ctx.state.devices[$0]?.udid }.map(CrashOrigin.simulator) ?? .anywhere
        var report: CrashReport?
        if let product, options.bundle == nil || options.bundle == product.bundleId {
            for _ in 0..<6 where report == nil {
                report = crashes.find(processName: product.executableName, since: since, from: origin)
                if report == nil { try? await supervisor.sleep(.milliseconds(500)) }
            }
        }
        guard let report else {
            return XcdError(.appCrashed, "the app stopped running during the \(what) (no crash report found)",
                            next: "see its last output with `xcd logs --app`, then start it again with `xcd run`")
        }
        let summary = [report.exception, report.termination].compactMap { $0 }.joined(separator: ", ")
        return XcdError(.appCrashed, "the app crashed during the \(what)" + (summary.isEmpty ? "" : ": \(summary)"),
                        next: "fix the crash, then start the app again with `xcd run`",
                        details: report.frames.map { "  " + $0 } + ["report: \(report.path)"])
    }

    func scope(_ options: UIOptions, in ctx: WorktreeContext) throws -> ActionScope {
        ActionScope(bundleId: try bundleId(options, in: ctx), system: options.system,
                    timeout: DurationText.seconds(options.effectiveTimeout), tree: options.tree)
    }

    /// Buttons and rotation act on the device, so they need no app: with none to name, they report on the Home Screen.
    func deviceScope(_ options: UIOptions, in ctx: WorktreeContext) -> ActionScope {
        let bundle = try? bundleId(options, in: ctx)
        return ActionScope(bundleId: bundle, system: bundle == nil, timeout: DurationText.seconds(options.effectiveTimeout), tree: options.tree)
    }

    /// `--tree` after a device action that did not go through the runner (a foldable's rotation): the tree is read as
    /// after any device action, from the Home Screen when no app resolves, and a failed read becomes a note.
    public func attachTreeAfterDeviceAction(to report: inout UIActionReport, _ options: UIOptions, in ctx: inout WorktreeContext) async {
        let scope = deviceScope(options, in: ctx)
        let request = TreeRequest(bundleId: scope.bundleId, system: scope.system, all: false)
        let exchange = RunnerExchange(path: RunnerProtocol.treePath, request: request, what: "read", resend: true)
        if let (_, result) = try? await send(exchange, as: TreeResult.self, options, in: &ctx), case .success(let tree) = result {
            report.tree = tree
        } else {
            report.notes.append(UIText.treeUnreadNote)
        }
    }

    public func longPress(_ target: String, duration: Duration, _ options: UIOptions,
                          in ctx: inout WorktreeContext) async throws -> UIActionReport {
        if isMac(options.device, in: ctx) { throw Self.macLongPress }
        guard duration >= .milliseconds(100), duration <= .seconds(20) else {
            throw XcdError(.usage, "--duration \(DurationText.format(duration)) is outside 0.1s to 20s", next: "pass a duration like 1s or 2.5s")
        }
        var request = try targetRequest(target, gone: false, options, in: ctx)
        request.tree = options.tree
        request.duration = DurationText.seconds(duration)
        let call = ActionCall(path: RunnerProtocol.longPressPath, request: request, what: "long-press", target: target)
        return try await act(call, options, in: &ctx).report("long-pressed", target: target, detail: "for \(DurationText.format(duration))")
    }

    public func swipe(_ swipe: SwipeOptions, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        // The engine would hand --from/--to to `drag`, which on a Mac scrolls the first scroll area.
        if swipe.from != nil || swipe.to != nil, isMac(options.device, in: ctx) {
            throw XcdError(.platformUnsupported, "a swipe between points does not reach a background Mac app",
                           next: "swipe on an element instead: `xcd ui swipe up --on <target>`")
        }
        let request = try swipeRequest(swipe, options, in: ctx)
        let target = swipe.on ?? "the screen"
        let done = try await act(ActionCall(path: RunnerProtocol.swipePath, request: request, what: "swipe", target: target), options, in: &ctx)
        let from = "\(ScreenRect.number(done.result.x ?? 0)),\(ScreenRect.number(done.result.y ?? 0))"
        let to = "\(ScreenRect.number(done.result.toX ?? 0)),\(ScreenRect.number(done.result.toY ?? 0))"
        guard let direction = request.direction else { return done.report("swiped", target: "from \(from) to \(to)") }
        // An element's line already says where the swipe began.
        return done.report("swiped \(direction.rawValue) on", target: target, detail: done.result.element == nil ? "from \(from) to \(to)" : "to \(to)")
    }

    static let swipeForms = "`xcd ui swipe up|down|left|right [--on <target>]`, or `xcd ui swipe --from x,y --to x,y`"

    func swipeRequest(_ swipe: SwipeOptions, _ options: UIOptions, in ctx: WorktreeContext) throws -> SwipeRequest {
        let scope = try self.scope(options, in: ctx)
        guard let name = swipe.direction else {
            guard swipe.on == nil, let from = swipe.from, let to = swipe.to else {
                throw XcdError(.usage, "a swipe needs a direction, or both --from and --to", next: "use " + Self.swipeForms)
            }
            return SwipeRequest(scope: scope, direction: nil, on: nil, from: try point(from, flag: "--from"), to: try point(to, flag: "--to"))
        }
        guard let direction = SwipeDirection(rawValue: name) else {
            throw XcdError(.usage, "'\(name)' is not a direction", next: "use one of: up, down, left, right")
        }
        guard swipe.from == nil, swipe.to == nil else {
            throw XcdError(.usage, "a direction and --from/--to can't be combined", next: "use " + Self.swipeForms)
        }
        let on = try swipe.on.map { try query($0, options) }
        if case .point? = on?.target {
            throw XcdError(.usage, "--on takes an element, not a point", next: "swipe between points with `xcd ui swipe --from x,y --to x,y`")
        }
        return SwipeRequest(scope: scope, direction: direction, on: on, from: nil, to: nil)
    }

    /// "x,y" (or "@x,y") in points.
    func point(_ text: String, flag: String) throws -> ScreenPoint {
        guard case .success(.point(let x, let y)) = TargetParser.parse(text.hasPrefix("@") ? text : "@" + text) else {
            throw XcdError(.usage, "\(flag) \(text) is not a point", next: "pass points as x,y, e.g. \(flag) 200,600")
        }
        return ScreenPoint(x: x, y: y)
    }

    /// Types into the element `--into` names, or into whatever has keyboard focus; an empty text only clears or submits.
    public func type(_ text: String, _ typing: TypeOptions, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        guard !text.isEmpty || typing.clear || typing.submit else {
            throw XcdError(.usage, "there is nothing to type", next: "pass some text, or --clear or --submit")
        }
        guard text.count <= Self.maxTypedCharacters else {
            throw XcdError(.usage, "the text is \(text.count) characters; one `xcd ui type` takes at most \(Self.maxTypedCharacters)",
                           next: "type it in parts")
        }
        let into = try typing.into.map { try query($0, options) }
        if case .point? = into?.target {
            throw XcdError(.usage, "--into takes an element, not a point", next: "tap the point with `xcd ui tap`, then type without --into")
        }
        let request = TypeRequest(scope: try scope(options, in: ctx), text: text, into: into, clear: typing.clear, submit: typing.submit)
        // About four characters a second, at the slowest.
        let call = ActionCall(path: RunnerProtocol.typePath, request: request, what: "typing", target: typing.into ?? "the focused element",
                              slack: .seconds(30) + .milliseconds(250 * text.count))
        let done = try await act(call, options, in: &ctx)
        let count = "\(text.count) character\(text.count == 1 ? "" : "s")"
        let how = ["by \(done.result.method ?? "keyboard")", typing.clear ? "after clearing" : nil, typing.submit ? "then Return" : nil]
        return done.report("typed \(count) into", target: typing.into ?? "the focused element", detail: how.compactMap { $0 }.joined(separator: ", "))
    }

    public func button(_ name: String, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        guard HardwareButton(rawValue: name) != nil else {
            throw XcdError(.usage, "'\(name)' is not a button", next: "use one of: " + HardwareButton.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let request = DeviceRequest(scope: deviceScope(options, in: ctx), name: name)
        let done = try await act(ActionCall(path: RunnerProtocol.buttonPath, request: request, what: "button press", target: name), options, in: &ctx)
        return done.report("pressed", target: name)
    }

    public func rotate(_ orientation: String, _ options: UIOptions, in ctx: inout WorktreeContext) async throws -> UIActionReport {
        guard DeviceOrientation(rawValue: orientation) != nil else {
            throw XcdError(.usage, "'\(orientation)' is not an orientation",
                           next: "use one of: " + DeviceOrientation.allCases.map(\.rawValue).joined(separator: ", "))
        }
        let request = DeviceRequest(scope: deviceScope(options, in: ctx), name: orientation)
        let done = try await act(ActionCall(path: RunnerProtocol.rotatePath, request: request, what: "rotation", target: orientation), options, in: &ctx)
        return done.report("rotated to", target: orientation)
    }

    /// The largest image file `xcd sim pasteboard set --image` takes: it travels to the runner inside one request.
    static let maxImageBytes = 16 * 1024 * 1024

    /// Puts an image file on the device's pasteboard through the runner: simctl can only copy text.
    public func setPasteboardImage(file: String, device: String?, in ctx: inout WorktreeContext) async throws -> DeviceStateReport {
        if isMac(device, in: ctx) {
            throw XcdError(.platformUnsupported, "the Mac's pasteboard is the person's; xcd never reads or writes it",
                           next: "copy on the Mac yourself, or use a simulator device")
        }
        guard let image = FileManager.default.contents(atPath: file), !image.isEmpty else {
            throw XcdError(.usage, "\(file) doesn't exist or is empty", next: "pass a PNG or JPEG file")
        }
        guard image.count <= Self.maxImageBytes else {
            throw XcdError(.usage, "\(file) is larger than 16 MB, the most xcd can copy", next: "pass a smaller image")
        }
        let options = UIOptions(device: device, bundle: nil, system: true, role: nil, index: nil, timeout: .zero)
        let exchange = RunnerExchange(path: RunnerProtocol.pasteboardPath, request: PasteboardRequest(image: image), what: "copy", resend: true)
        let (session, result) = try await send(exchange, as: PasteboardResult.self, options, in: &ctx)
        switch result {
        case .success(let set) where set.hasImages:
            break
        case .failure(let failure) where failure.code != RunnerFailure.Code.badRequest || failure.message != PasteboardRequest.notAnImage:
            throw UIRunnerErrors.error(failure, target: file, timeout: .zero)
        case .success, .failure:                // the runner says it is not an image, or the pasteboard holds none
            throw XcdError(.usage, "\(file) is not an image iOS can read", next: "pass a PNG or JPEG file")
        }
        return DeviceStateReport(action: "set the pasteboard to the image \((file as NSString).lastPathComponent) (\(image.count) bytes)",
                                 device: session.device, udid: session.udid, worktree: ctx.state.name)
    }
}
