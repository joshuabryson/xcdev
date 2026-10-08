import Foundation
import Testing
@testable import XcdevKit

/// What SwiftLint does with each config here was checked against SwiftLint 0.63.3 in a folder with a `.xcdev/`.
@Suite struct SwiftLintConfigTests {
    func config(_ text: String) -> SwiftLintConfig { SwiftLintConfig(path: "/p/.swiftlint.yml", text: text) }

    /// A config like the one whose build first showed the problem: SwiftLint spent minutes in `.xcdev/`.
    static let usual = """
    excluded:
      - DerivedData
      - build
      - .build

    disabled_rules:
      - trailing_whitespace
      - todo

    type_name:
      excluded:
        - Widget_Extension

    """

    @Test func swiftLintSearchesHiddenFoldersUnlessToldNotTo() {
        #expect(config(Self.usual).searchesStateFolder)
        #expect(config("disabled_rules:\n  - todo\n").searchesStateFolder)
        #expect(config("").searchesStateFolder)
        #expect(config("# only a comment\n").searchesStateFolder)
        #expect(config("excluded:\n").searchesStateFolder)
    }

    @Test(arguments: ["excluded:\n  - .xcdev\n", "excluded:\n  - .xcdev/\n", "excluded:\n  - ./.xcdev\n", "excluded:\n  - \".xcdev\"\n",
                      "excluded: [Pods, .xcdev]\n", "excluded: .xcdev\n", "excluded:\n  - .xcdev/*\n", "excluded:\n  - .xcdev/**\n",
                      "excluded:\n  - .xc*\n", "excluded:\n  - '.*'\n", "excluded:\n- Pods\n- .xcdev\n"])
    func anExclusionThatCoversTheFolderKeepsSwiftLintOut(yaml: String) {
        #expect(!config(yaml).searchesStateFolder)
        #expect(config(yaml).excludingStateFolder == nil, "nothing to add")
    }

    @Test func excludingPartOfTheFolderLeavesTheRestSearched() {
        #expect(config("excluded:\n  - .xcdev/DerivedData\n").searchesStateFolder)
        #expect(config("type_name:\n  excluded:\n    - .xcdev\n").searchesStateFolder, "a rule's own list of names, not paths")
    }

    @Test func anIncludedListDecidesWhatIsSearched() {
        #expect(!config("included:\n  - App\n  - AppTests\n").searchesStateFolder)
        #expect(!config("included: App\n").searchesStateFolder)
        #expect(config("included:\n  - .\n").searchesStateFolder)
        #expect(config("included:\n  - ./\n  - Extras\n").searchesStateFolder)
        #expect(config("included: []\n").searchesStateFolder, "an empty list is no list")
        #expect(!config("included:\n  - .\nexcluded:\n  - .xcdev\n").searchesStateFolder)
    }

    @Test func theFolderJoinsTheListAfterItsLastItem() {
        #expect(config(Self.usual).excludingStateFolder == """
        excluded:
          - DerivedData
          - build
          - .build
          - .xcdev

        disabled_rules:
          - trailing_whitespace
          - todo

        type_name:
          excluded:
            - Widget_Extension

        """)
    }

    @Test func itemsKeepTheListsOwnIndentation() {
        #expect(config("excluded:\n- Pods\n- build\nline_length: 120\n").excludingStateFolder
                == "excluded:\n- Pods\n- build\n- .xcdev\nline_length: 120\n")
        #expect(config("excluded:\n    - Pods\n").excludingStateFolder == "excluded:\n    - Pods\n    - .xcdev\n")
    }

    @Test func commentsAndBlankLinesAroundTheListStayWhereTheyAre() {
        let yaml = """
        # what to lint
        excluded: # generated code
          - Pods   # CocoaPods
          # ours
          - Generated

          # rules
        opt_in_rules:
          - empty_count
        """
        #expect(config(yaml).excludingStateFolder == """
        # what to lint
        excluded: # generated code
          - Pods   # CocoaPods
          # ours
          - Generated
          - .xcdev

          # rules
        opt_in_rules:
          - empty_count
        """)
    }

    @Test func aListThatEndsTheFileWithoutANewlineGetsOne() {
        #expect(config("excluded:\n  - Pods").excludingStateFolder == "excluded:\n  - Pods\n  - .xcdev\n")
    }

    @Test func anItemThatRunsOverSeveralLinesIsNotSplit() {
        #expect(config("excluded:\n  - Pods\n  - >-\n    Generated\n    Code\nline_length: 120\n").excludingStateFolder
                == "excluded:\n  - Pods\n  - >-\n    Generated\n    Code\n  - .xcdev\nline_length: 120\n")
    }

    @Test func aListOnOneLineGetsTheFolderBeforeItsBracket() {
        #expect(config("excluded: [Pods, build]\n").excludingStateFolder == "excluded: [Pods, build, .xcdev]\n")
        #expect(config("excluded: [ Pods ]  # generated\n").excludingStateFolder == "excluded: [ Pods, .xcdev ]  # generated\n")
        #expect(config("excluded: []\nline_length: 120\n").excludingStateFolder == "excluded: [.xcdev]\nline_length: 120\n")
        #expect(config("excluded: [Pods] # see [docs]\n").excludingStateFolder == "excluded: [Pods, .xcdev] # see [docs]\n")
    }

    @Test func anEmptyListGetsItsFirstItem() {
        #expect(config("excluded:\nline_length: 120\n").excludingStateFolder == "excluded:\n  - .xcdev\nline_length: 120\n")
    }

    @Test func aConfigWithoutTheListGetsOneAtItsEnd() {
        #expect(config("disabled_rules:\n  - todo\n").excludingStateFolder == "disabled_rules:\n  - todo\n\nexcluded:\n  - .xcdev\n")
        #expect(config("disabled_rules:\n  - todo").excludingStateFolder == "disabled_rules:\n  - todo\n\nexcluded:\n  - .xcdev\n")
        #expect(config("disabled_rules:\n  - todo\n\n").excludingStateFolder == "disabled_rules:\n  - todo\n\nexcluded:\n  - .xcdev\n")
        #expect(config("").excludingStateFolder == "excluded:\n  - .xcdev\n")
        // A rule's own `excluded` is not the list of paths.
        #expect(config("type_name:\n  excluded:\n    - Widget\n").excludingStateFolder
                == "type_name:\n  excluded:\n    - Widget\n\nexcluded:\n  - .xcdev\n")
    }

    @Test func windowsLineEndingsAreKept() {
        #expect(config("excluded:\r\n  - Pods\r\nline_length: 120\r\n").excludingStateFolder
                == "excluded:\r\n  - Pods\r\n  - .xcdev\r\nline_length: 120\r\n")
        #expect(config("line_length: 120\r\n").excludingStateFolder == "line_length: 120\r\n\r\nexcluded:\r\n  - .xcdev\r\n")
    }

    /// Layouts the edit doesn't know. It gives nothing rather than a file that reads differently, and the caller
    /// asks for the line to be added by hand.
    @Test(arguments: ["excluded: Pods\n", "excluded: [Pods,\n  build]\n", "excluded: [Pods, build,]\n", "\"excluded\":\n  - Pods\n",
                      "excluded: &generated\n  - Pods\n"])
    func aLayoutItCannotEditSafelyIsLeftForAPerson(yaml: String) {
        #expect(config(yaml).searchesStateFolder)
        #expect(config(yaml).excludingStateFolder == nil)
    }

    /// SwiftLint warns about a config it can't read, at most, and carries on with its defaults: everything is searched.
    @Test(arguments: ["excluded: [\n", "- Pods\n- .xcdev\n", "just text\n"])
    func aConfigSwiftLintCannotReadCountsAsNoConfig(yaml: String) {
        #expect(config(yaml).searchesStateFolder)
        #expect(config(yaml).excludingStateFolder == nil)
    }

    @Test func theConfigIsReadFromTheProjectFolderAndWrittenBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcdev-lint-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        #expect(SwiftLintConfig.load(in: root) == nil)

        try "excluded:\n  - Pods\n".write(toFile: root + "/.swiftlint.yml", atomically: true, encoding: .utf8)
        let found = try #require(SwiftLintConfig.load(in: root))
        #expect(found.path == root + "/.swiftlint.yml" && found.searchesStateFolder)
        #expect(try found.excludeStateFolder())
        #expect(try String(contentsOfFile: root + "/.swiftlint.yml", encoding: .utf8) == "excluded:\n  - Pods\n  - .xcdev\n")

        let again = try #require(SwiftLintConfig.load(in: root))
        #expect(!again.searchesStateFolder)
        #expect(try !again.excludeStateFolder(), "nothing to add, so nothing is written")
    }
}
