import Foundation

/// The engine's text as key events: a character key carries its text; Return, Tab, and Delete are key codes.
public enum MacKeys {
    public static let returnKey: UInt16 = 36
    public static let tab: UInt16 = 48
    public static let delete: UInt16 = 51

    public static func events(for text: String) -> [MacKey] {
        text.map { character in
            switch character {
            case "\n", "\r", "\r\n": return MacKey(code: returnKey, text: nil)
            case "\t": return MacKey(code: tab, text: nil)
            case "\u{8}", "\u{7F}": return MacKey(code: delete, text: nil)
            default: return MacKey(code: 0, text: String(character))
            }
        }
    }
}
