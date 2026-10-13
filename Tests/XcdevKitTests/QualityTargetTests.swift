import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// What `xcd lint` and `xcd format` cover. Git is real.
@Suite struct QualityTargetTests {
    /// `main` holds A.swift and B.swift under Sources/App. On branch `work`, A.swift is edited and Tests/C.swift is new.
    func project() throws -> TempProject {
        let project = try TempProject.make(config: "version: 1\nproject: App.xcodeproj\n")
        try project.write("let a = 1\n", to: "Sources/App/A.swift")
        try project.write("let b = 1\n", to: "Sources/App/B.swift")
        try project.commit("Base")
        try project.git("checkout", "-q", "-b", "work")
        try project.write("let a = 2\n", to: "Sources/App/A.swift")
        try project.write("let c = 1\n", to: "Tests/C.swift")
        return project
    }

    func finder(_ project: TempProject, from directory: String? = nil) -> TargetFinder {
        TargetFinder(runner: SystemProcessRunner(), currentDirectory: directory ?? project.root)
    }

    func context(_ project: TempProject) async throws -> WorktreeContext {
        try await WorktreeService(runner: SystemProcessRunner(), globalPaths: GlobalPaths(base: project.home)).open(from: project.root)
    }

    @Test func theFlagsNameOneScope() throws {
        #expect(try QualityScope.named(files: false, all: false, base: nil, otherwise: "") == .lines)
        #expect(try QualityScope.named(files: true, all: false, base: "main", otherwise: "") == .files)
        #expect(try QualityScope.named(files: false, all: true, base: nil, otherwise: "") == .all)
    }

    @Test func twoScopesOrABaseWithAllAreUsageErrors() {
        let both = #expect(throws: XcdError.self) {
            _ = try QualityScope.named(files: true, all: true, base: nil, otherwise: "to reformat only the lines the change touched")
        }
        #expect(both?.code == .usage && both?.message == "--files and --all are two scopes")
        #expect(both?.next == "pass one of them, or neither to reformat only the lines the change touched")
        let based = #expect(throws: XcdError.self) { _ = try QualityScope.named(files: false, all: true, base: "main", otherwise: "") }
        #expect(based?.code == .usage && based?.next == "drop one of the two")
    }

    @Test func theChangeIsMeasuredFromTheBaseAndAllFromNothing() async throws {
        let project = try project()
        defer { project.remove() }
        let ctx = try await context(project)
        let changed = try await finder(project).target(.lines, paths: [], base: nil, in: ctx)
        #expect(changed.base?.name == "main" && changed.scope == .lines)
        #expect(changed.files == [ScopedFile(path: "Sources/App/A.swift", basePath: "Sources/App/A.swift"), ScopedFile(path: "Tests/C.swift", basePath: nil)])
        let all = try await finder(project).target(.all, paths: [], base: nil, in: ctx)
        #expect(all.base == nil && all.files.map(\.path) == ["Sources/App/A.swift", "Sources/App/B.swift", "Tests/C.swift"])
    }

    @Test func pathsNarrowBothAndAreReadFromTheCurrentDirectory() async throws {
        let project = try project()
        defer { project.remove() }
        let ctx = try await context(project)
        let finder = finder(project, from: project.root + "/Sources")
        #expect(try await finder.target(.all, paths: ["App/B.swift"], base: nil, in: ctx).files.map(\.path) == ["Sources/App/B.swift"])
        let narrowed = try await finder.target(.files, paths: ["App"], base: "main", in: ctx)
        #expect(narrowed.files.map(\.path) == ["Sources/App/A.swift"] && narrowed.paths.prefixes == ["Sources/App"])
        let outside = await #expect(throws: XcdError.self) { _ = try await finder.target(.lines, paths: ["/etc"], base: nil, in: ctx) }
        #expect(outside?.code == .usage)
    }
}
