import Foundation

/// Role names for `XCUIElement.ElementType` raw values. The runner checks a sample of these against the real enum at
/// start-up and reports the result in `/health`.
public enum ElementRole {
    static let names: [Int: String] = [
        2: "application", 3: "group", 4: "window", 5: "sheet", 7: "alert", 8: "dialog", 9: "button", 10: "radioButton",
        12: "checkBox", 14: "popUpButton", 16: "menuButton", 17: "toolbarButton", 18: "popover", 19: "keyboard", 20: "key",
        21: "navigationBar", 22: "tabBar", 24: "toolbar", 25: "statusBar", 26: "table", 32: "collectionView", 33: "slider",
        34: "pageIndicator", 35: "progressIndicator", 36: "activityIndicator", 37: "segmentedControl", 38: "picker",
        39: "pickerWheel", 40: "switch", 41: "toggle", 42: "link", 43: "image", 44: "icon", 45: "searchField",
        46: "scrollView", 48: "text", 49: "textField", 50: "secureTextField", 51: "datePicker", 52: "textView", 53: "menu",
        54: "menuItem", 57: "map", 58: "webView", 75: "cell", 79: "stepper", 80: "tab",
    ]

    public static func name(for elementType: Int) -> String { names[elementType] ?? "other" }

    /// Roles an agent acts on. They are shown even without a label.
    public static let interactive: Set<String> = [
        "button", "radioButton", "checkBox", "popUpButton", "menuButton", "toolbarButton", "slider", "segmentedControl",
        "pickerWheel", "switch", "toggle", "link", "searchField", "textField", "secureTextField", "datePicker", "textView",
        "menuItem", "cell", "stepper", "tab",
    ]

    /// Containers. They are hidden by default even when they have a label. `other` is not one of them: a custom view
    /// with a label is often the thing to tap.
    public static let structural: Set<String> = [
        "application", "window", "group", "keyboard", "key", "navigationBar", "tabBar", "toolbar", "statusBar", "table",
        "collectionView", "scrollView",
    ]
}
