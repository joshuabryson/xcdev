import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// swift-format is handed the lines a change touched as UTF-8 offsets into the file's text. The
/// stand-in reads them back as the lines they touch, so an offset that is out by a byte reformats a line beside them.
@Suite struct AppleSwiftFormatRangesTests {
    let formatters = FakeFormatters()

    /// Above the change, each accented letter takes two bytes, and the byte order mark three that swift-format does
    /// not count: it reads the file as text, and the mark is not text. Lines 3 and 5, around the change, are as the
    /// formatter would not leave them.
    @Test func onlyTheChangedLineIsReformattedBelowAccentsAndAByteOrderMark() async throws {
        let project = try FormatProject(FormatProject.appleSwiftFormat)
        defer { project.project.remove() }
        let mark = Data([0xEF, 0xBB, 0xBF])
        let base = "// Été à Noël  \nstruct É {\n    let é = 1  \n    let b = 2\n\tlet c = 3\n}\n"
        let url = URL(fileURLWithPath: project.root + "/Sources/App/Accents.swift")
        try (mark + Data(base.utf8)).write(to: url)
        _ = try project.project.commit("Accents")
        try project.project.git("branch", "-f", "main", "HEAD")
        try (mark + Data(base.replacingOccurrences(of: "let b = 2\n", with: "let b = 20  \n").utf8)).write(to: url)
        let ctx = try await project.context()
        let report = try await project.service(formatters).format(FormatOptions(), in: ctx)

        #expect(report.failure == nil && report.changed.map(\.file) == ["Sources/App/Accents.swift"])
        #expect(report.changed.first?.lines == [LineRange(4, 4)])
        #expect(try Data(contentsOf: url) == mark + Data(base.replacingOccurrences(of: "let b = 2\n", with: "let b = 20\n").utf8))
    }
}
