import Foundation

/// The source files a build compiled, read from xcodebuild's log. xcodebuild reports
/// a file's warnings only in a build that compiles it, and its log names every file a build compiles.
enum CompiledFiles {
    /// The kinds of file whose compiling a log shows, and so whose warnings xcd keeps from one build to the next.
    static let kept: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "cxx"]

    static func isKept(_ path: String) -> Bool { kept.contains((path as NSString).pathExtension.lowercased()) }

    /// Every kept file a `SwiftCompile` or `CompileC` line of `log` names, by its path as the log gives it.
    static func parse(_ log: String) -> Set<String> {
        var files = Set<String>()
        for line in log.split(separator: "\n") where line.hasPrefix("SwiftCompile ") || line.hasPrefix("CompileC ") {
            files.formUnion(named(by: words(String(line))))
        }
        return files
    }

    /// The files one compile line names. Its words end at `(in`, which starts ` (in target '…')`. In a `SwiftCompile`
    /// line every word that is an absolute path is a compiled file; a batch line names several, after a description.
    /// A `CompileC` line names the object file first and the compiled file second.
    static func named(by words: [String]) -> [String] {
        let named = words.prefix { $0 != "(in" }.dropFirst()
        let files = words.first == "CompileC" ? Array(named.dropFirst().prefix(1)) : Array(named)
        return files.filter { $0.hasPrefix("/") && isKept($0) }
    }

    /// The words of a line, which spaces separate. A backslash makes the next character part of the word, so a path's
    /// spaces and quotes, written `\ ` and `\'`, are in it.
    static func words(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var escaped = false
        for character in line {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == " " {
                if !word.isEmpty { words.append(word) }
                word = ""
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
