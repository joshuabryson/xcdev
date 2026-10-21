import Foundation

/// AX roles and subroles as the engine's element types. A role the table does not know is `other`.
public enum MacRoles {
    /// Subroles that name a different control than their role. `AXDialog` is not one of them: SwiftUI's own main
    /// window reports it, so a window is a window whatever its subrole, except a system dialog.
    static let bySubrole: [String: Int] = [
        "AXToolbarButton": 17, "AXSwitch": 40, "AXToggle": 41, "AXSecureTextField": 50, "AXSearchField": 45, "AXSystemDialog": 7,
    ]
    static let byRole: [String: Int] = [
        "AXApplication": 2, "AXWindow": 4, "AXSheet": 5, "AXDialog": 8, "AXDrawer": 3, "AXGroup": 3, "AXSplitGroup": 3, "AXLayoutArea": 3,
        "AXToolbar": 24, "AXButton": 9, "AXRadioButton": 10, "AXRadioGroup": 37, "AXCheckBox": 12, "AXPopUpButton": 14,
        "AXMenuButton": 16, "AXMenu": 53, "AXMenuItem": 54, "AXMenuBarItem": 54, "AXPopover": 18, "AXTextField": 49, "AXTextArea": 52,
        "AXStaticText": 48, "AXLink": 42, "AXImage": 43, "AXSlider": 33, "AXIncrementor": 79, "AXProgressIndicator": 35,
        "AXBusyIndicator": 36, "AXTable": 26, "AXOutline": 26, "AXList": 26, "AXRow": 75, "AXCell": 75, "AXScrollArea": 46,
        "AXScrollBar": 47, "AXTabGroup": 23, "AXDateField": 51, "AXDatePicker": 51,
    ]
    /// Element types the driver focuses instead of pressing.
    public static let textEntry: Set<Int> = [45, 49, 50, 52]

    public static func elementType(role: String, subrole: String?) -> Int {
        if let subrole, let type = bySubrole[subrole] { return type }
        return byRole[role] ?? 0
    }

    /// A radio button inside a tab group is a tab.
    public static func elementType(role: String, subrole: String?, parentType: Int?) -> Int {
        let type = elementType(role: role, subrole: subrole)
        return type == 10 && parentType == 23 ? 80 : type
    }
}
