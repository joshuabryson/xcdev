import Foundation

extension RunnerEngine {
    /// Keys as a hardware keyboard sends them (`XCUIKeyboardKey`'s raw values).
    enum Keys {
        static let delete = "\u{8}"
        static let enter = "\r"
    }

    /// Seconds to wait for the keyboard before pasting instead of typing.
    static let keyboardWait = 1.5
    /// Never sent to xcd: what a look for the keyboard says while there is none.
    static let noKeyboard = RunnerFailure(code: "no_keyboard", message: "no keyboard is on screen")
    static let nothingFocused = RunnerFailure(code: RunnerFailure.Code.nothingFocused, message: "nothing has keyboard focus")

    /// How text can be entered: through the keyboard on screen, by pasting into the element that has keyboard focus,
    /// or not at all.
    enum TextEntry {
        case keyboard, paste, nowhere
    }

    public func enterText(_ request: TypeRequest) -> Result<ActionResult, RunnerFailure> {
        let scope = request.scope
        if let refusal = refusal(scope) { return .failure(refusal) }
        let start = device.now()
        var focused = ActionResult(element: nil, x: nil, y: nil, ms: 0)
        if let into = request.into {
            switch focus(into, scope) {
            case .failure(let failure): return .failure(failure)
            case .success(let result): focused = result
            }
        }
        switch textEntry(scope) {
        case .failure(let failure):
            return .failure(failure)
        case .success(.nowhere):
            return .failure(Self.nothingFocused)
        case .success(let entry):
            let keyboard = entry == .keyboard
            return performed("typing", { Int((self.device.now() - start) * 1000) }, { try self.entered(request, keyboard: keyboard, into: focused) })
                .flatMap { finished($0, scope, what: "typing", appWasRunning: true) }
        }
    }

    /// Taps the field so it takes keyboard focus. The tap sends no tree back: the typing does, at the end.
    func focus(_ query: ElementQuery, _ scope: ActionScope) -> Result<ActionResult, RunnerFailure> {
        var scope = scope
        scope.tree = false
        return onElement(query, scope, what: "tap") { node, scene in
            try self.device.tap(x: node.frame.midX, y: node.frame.midY)
            return ActionResult(element: TreeBuilder.element(node, ref: nil, screen: scene.screen), x: node.frame.midX, y: node.frame.midY, ms: 0)
        }
    }

    /// How text can be entered, looking for a keyboard for up to `keyboardWait` seconds. An app that isn't in front is
    /// a failure. The one-time tip card over a new simulator's keyboard is dismissed on the way. With no keyboard, the
    /// text is pasted, unless the last look says that nothing has keyboard focus: a paste then goes nowhere, and
    /// XCTest reports no problem with it, so it would pass for typing that worked.
    func textEntry(_ scope: ActionScope) -> Result<TextEntry, RunnerFailure> {
        var scope = scope
        scope.timeout = Self.keyboardWait
        var focus: Bool?
        let found = poll(scope, what: "typing") { scene, elapsedMs in
            if scene.appAway { return .retry(self.appAwayFailure(scene)) }
            focus = Self.keyboardFocus(in: scene)
            if let card = self.tipCardButton(in: scene) {
                try? self.device.tap(x: card.frame.midX, y: card.frame.midY)
                return .retry(Self.noKeyboard)
            }
            guard self.keyboardArea(in: scene) != nil else { return .retry(Self.noKeyboard) }
            return .done(.success(ActionResult(element: nil, x: nil, y: nil, ms: elapsedMs())))
        }
        switch found {
        case .success: return .success(.keyboard)
        case .failure(let failure) where failure.code != Self.noKeyboard.code: return .failure(failure)
        case .failure: return .success(focus == false ? .nowhere : .paste)
        }
    }

    /// Whether an element on screen has keyboard focus; nil when the device doesn't say so for every element.
    static func keyboardFocus(in scene: Scene) -> Bool? {
        if scene.nodes.contains(where: { $0.focused == true }) { return true }
        return scene.nodes.isEmpty || scene.nodes.contains(where: { $0.focused == nil }) ? nil : false
    }

    /// The Continue button of the tip card ("Speed up your typing…") a new simulator shows over its keyboard once.
    func tipCardButton(in scene: Scene) -> FlatNode? {
        guard scene.nodes.contains(where: { $0.label.hasPrefix("Speed up your typing") }) else { return nil }
        return scene.nodes.first { $0.role == "button" && $0.label == "Continue" && TreeBuilder.isOnScreen($0, screen: scene.screen) }
    }

    /// Enters the text: through the keyboard when one is up, else by pasting, which never calls `typeText`
    /// (it fails without a software keyboard). `--clear` selects everything first, so what follows replaces it.
    func entered(_ request: TypeRequest, keyboard: Bool, into focused: ActionResult) throws -> ActionResult {
        if request.clear { try device.pressKey("a", command: true) }
        if keyboard {
            let text = (request.clear ? Keys.delete : "") + request.text + (request.submit ? "\n" : "")
            if !text.isEmpty { try device.typeText(text) }
        } else {
            try paste(request)
        }
        var result = focused
        result.method = keyboard ? "keyboard" : "paste"
        return result
    }

    func paste(_ request: TypeRequest) throws {
        if !request.text.isEmpty {
            device.setPasteboard(text: request.text)
            try device.pressKey("v", command: true)
        } else if request.clear {
            try device.pressKey(Keys.delete, command: false)
        }
        if request.submit { try device.pressKey(Keys.enter, command: false) }
    }
}
