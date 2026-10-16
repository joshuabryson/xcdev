import Foundation
import Testing
@testable import XcdevKit

/// What a build, run, or test result shows of the warnings xcd knows. Real
/// files, a record made the way a build makes it, and the touched files given as git would give them.
@Suite struct KnownWarningsTests {
    let folder = WarningFolder()

    /// What this build saw: its warnings, and the files it compiled.
    func sight(_ warnings: [Diagnostic], compiled: Set<String>) -> WarningSight {
        WarningSight(warnings: warnings, count: warnings.count, compiled: compiled)
    }

    func touched(_ names: String...) -> [String: String] {
        Dictionary(uniqueKeysWithValues: names.compactMap { name in Disk.realPath(folder.path + "/" + name).map { ($0, name) } })
    }

    /// The first build saw Login's and Session's warnings and Other's; the second compiled only Login.
    @Test func earlierWarningsOfTouchedFilesComeAfterThisBuildsAndTheRestAreCounted() throws {
        defer { folder.remove() }
        let login = try folder.file("Login.swift"), session = try folder.file("Session.swift"), other = try folder.file("Other.swift")
        let first = [Diagnostic.warning(login, 42, "never used"), Diagnostic.warning(session, 8, "deprecated"), Diagnostic.warning(other, 1, "other")]
        let record = WarningRecord().updated(compiled: [login, session, other], warnings: first)
            .updated(compiled: [login], warnings: [Diagnostic.warning(login, 42, "never used")])
        let known = KnownWarnings.of(sight([Diagnostic.warning(login, 42, "never used")], compiled: [login]), record: record,
                                     touched: touched("Login.swift", "Session.swift"))
        #expect(known.count == 3 && known.unknown.isEmpty)
        var earlier = Diagnostic.warning(session, 8, "deprecated")
        earlier.earlier = true
        #expect(known.changed == [Diagnostic.warning(login, 42, "never used"), earlier])
        #expect(known.listing(all: false) == [Diagnostic.warning(login, 42, "never used").text, "from earlier builds:", earlier.text])
        #expect(known.countLine(errors: nil, more: "xcd build --warnings")
                == "2 warnings in the files you changed (1 from an earlier build), 1 in other files (xcd build --warnings)")
        #expect(known.all.map(\.message) == ["never used", "other", "deprecated"])        // the earlier ones in path order
        #expect(known.listing(all: true).count == 4)                                   // with the line before the earlier ones
        #expect(known.countLine(errors: nil, more: "xcd build --warnings")?.hasSuffix("1 in other files (xcd build --warnings)") == true)
    }

    @Test func theCountLineReadsAsWhatThereIs() throws {
        defer { folder.remove() }
        let a = try folder.file("A.swift"), b = try folder.file("B.swift")
        let both = sight([Diagnostic.warning(a, 1, "a"), Diagnostic.warning(b, 1, "b")], compiled: [a, b])
        let record = WarningRecord().updated(compiled: both.compiled, warnings: both.warnings)
        let more = "xcd test --warnings"
        #expect(KnownWarnings.of(both, record: record, touched: [:]).countLine(errors: nil, more: more) == "2 warnings in other files (xcd test --warnings)")
        #expect(KnownWarnings.of(both, record: record, touched: touched("A.swift", "B.swift")).countLine(errors: nil, more: more)
                == "2 warnings in the files you changed")
        #expect(KnownWarnings.of(both, record: record, touched: nil).countLine(errors: 3, more: more) == "3 errors, 2 warnings (xcd test --warnings)")
        #expect(KnownWarnings.of(both, record: record, touched: touched("A.swift")).countLine(errors: nil, more: more)
                == "1 warning in the files you changed, 1 in other files (xcd test --warnings)")
        let none = KnownWarnings.of(sight([], compiled: []), record: WarningRecord(), touched: [:])
        #expect(none.countLine(errors: nil, more: more) == nil && none.countLine(errors: 1, more: more) == "1 error, 0 warnings")
        // With every warning listed, nothing is left to name the flag for.
        #expect(KnownWarnings.of(both, record: record, touched: nil).countLine(errors: nil, more: more, listedAll: true) == "2 warnings")
    }

    /// A touched file that changed since its warnings were recorded, and that this build did not compile, shows none.
    @Test func aTouchedFileThatChangedAndWasNotCompiledIsNotKnown() throws {
        defer { folder.remove() }
        let feed = try folder.file("Sources/App/Feed.swift"), done = try folder.file("Done.swift")
        let record = WarningRecord().updated(compiled: [feed, done], warnings: [Diagnostic.warning(feed, 3, "unused"), Diagnostic.warning(done, 1, "x")])
        try "let feed = 2\n".write(toFile: feed, atomically: false, encoding: .utf8)
        let known = KnownWarnings.of(sight([], compiled: []), record: record, touched: touched("Sources/App/Feed.swift", "Done.swift"))
        #expect(known.unknown == ["Sources/App/Feed.swift"] && known.count == 1)
        #expect(known.changed?.map(\.message) == ["x"])
        #expect(known.unknownLine == "warnings not known for 1 changed file, which this build did not compile: Sources/App/Feed.swift")
    }

    /// A header's warning is this build's only, and it is shown when the change touched the header.
    @Test func aWarningInATouchedHeaderIsShownAndNotKept() throws {
        defer { folder.remove() }
        let header = try folder.file("Obj.h"), source = try folder.file("Obj.m")
        let seen = sight([Diagnostic.warning(header, 2, "in the header")], compiled: [source])
        let record = WarningRecord().updated(compiled: seen.compiled, warnings: seen.warnings)
        let known = KnownWarnings.of(seen, record: record, touched: touched("Obj.h"))
        #expect(known.changed?.map(\.message) == ["in the header"] && known.count == 1)
        #expect(KnownWarnings.of(sight([], compiled: [source]), record: record, touched: touched("Obj.h")).count == 0)
    }

    @Test func anEarlierWarningIsMarkedInJSON() throws {
        var earlier = Diagnostic(.warning, "deprecated", file: "/p/S.swift", line: 8, column: 5)
        let plain = String(decoding: try JSONCoding.encoder(pretty: false).encode(earlier), as: UTF8.self)
        earlier.earlier = true
        let marked = String(decoding: try JSONCoding.encoder(pretty: false).encode(earlier), as: UTF8.self)
        #expect(!plain.contains("earlier") && marked.contains(#""earlier":true"#))
    }
}
