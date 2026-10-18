import Foundation

/// The name xcd gives a checkout it did not make, the first time it sees it.
enum CheckoutName {
    static let limit = 100

    /// The checkout's folder name, unless that fails `WorktreeService.validate` or is taken: another name in `held` is
    /// the same but for case (lock files and media folders live on a volume that ignores case), and `main` always is.
    /// Then the parent folder's name and the folder's, joined by `-`, with every character a name does not allow (and
    /// every `.`) made `-`, and `-2`, `-3`, … added while the name is taken. Every name it gives passes `validate`.
    static func choose(for path: String, held: Set<String>) -> String {
        let taken = Set(held.union(["main"]).map { $0.lowercased() })
        let folder = (path as NSString).lastPathComponent
        if isValid(folder), !taken.contains(folder.lowercased()) { return folder }
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let base = cleaned(parent + "-" + folder)
        // At most `taken.count` of these are taken, so one is free unless `validate` rejects them all.
        for number in 1...(taken.count + 1) {
            let suffix = number == 1 ? "" : "-\(number)"
            let name = String(base.prefix(limit - suffix.count)) + suffix
            if isValid(name), !taken.contains(name.lowercased()) { return name }
        }
        return "checkout-" + UUID().uuidString.prefix(8)
    }

    /// `text` with only letters, digits, `_` and `-`, starting with a letter or digit; `checkout` when nothing is left.
    static func cleaned(_ text: String) -> String {
        let kept = String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") ? $0 : "-" })
        let start = kept.drop { !($0.isLetter || $0.isNumber) }
        return start.isEmpty ? "checkout" : String(start)
    }

    static func isValid(_ name: String) -> Bool {
        (try? WorktreeService.validate(name: name)) != nil
    }
}
