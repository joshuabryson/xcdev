import Foundation
import Testing
@testable import XcdevKit

/// The source files a build compiled, as its log names them. The lines are as the
/// build logs of Xcode 27.0 had them, with shorter paths.
@Suite struct CompiledFilesTests {
    @Test func aDebugBuildNamesEachFileOrABatchOfThem() {
        let log = """
            SwiftDriver Lib normal arm64 com.apple.xcode.tools.swift.compiler (in target 'Lib' from project 'Lib')
            SwiftEmitModule normal arm64 Emitting\\ module\\ for\\ Lib (in target 'Lib' from project 'Lib')
            SwiftCompile normal arm64 (in target 'Lib' from project 'Lib')
            SwiftCompile normal arm64 /P/Many/Sources/Lib/F1.swift (in target 'Lib' from project 'Lib')
                cd /P/Many
                builtin-swiftTaskExecution -- /Xcode/swift-frontend -frontend -c /P/Many/Sources/Lib/F9.swift
            SwiftCompile normal arm64 Compiling\\ F39.swift,\\ F4.swift /P/Many/Sources/Lib/F39.swift /P/Many/Sources/Lib/F4.swift (in target 'Lib' from project 'Lib')
            SwiftDriverJobDiscovery normal arm64 Compiling F7.swift, F8.swift (in target 'Lib' from project 'Lib')
            CompileC /T/dd/Build/Intermediates.noindex/Lib.build/Debug/Obj-t.build/Objects-normal/arm64/Obj.o /P/Many/Sources/Obj/Obj.m normal arm64 objective-c com.apple.compiler (in target 'Obj' from project 'Lib')
            Ld /T/dd/Build/Products/Debug/Lib.o normal (in target 'Lib' from project 'Lib')
            ** BUILD SUCCEEDED **
            """
        #expect(CompiledFiles.parse(log) == ["/P/Many/Sources/Lib/F1.swift", "/P/Many/Sources/Lib/F39.swift", "/P/Many/Sources/Lib/F4.swift",
                                             "/P/Many/Sources/Obj/Obj.m"])
    }

    /// A release build compiles the whole module at once: one line names every file.
    @Test func aWholeModuleBuildNamesEveryFileOnOneLine() {
        let log = "SwiftCompile normal arm64 Compiling\\ A.swift,\\ B.swift /P/Sources/Lib/A.swift /P/Sources/Lib/B.swift (in target 'Lib' from project 'Lib')\n"
        #expect(CompiledFiles.parse(log) == ["/P/Sources/Lib/A.swift", "/P/Sources/Lib/B.swift"])
    }

    /// A space and a quote in a path are written with a backslash before them.
    @Test func pathsWithSpacesAndQuotesAreOneWordEach() {
        let log = """
            SwiftCompile normal arm64 Compiling\\ A\\ file.swift /P/Space\\ Dir/Pkg/Sources/My\\ Lib/A\\ file.swift (in target 'Lib' from project 'Lib')
            SwiftCompile normal arm64 /P/Space\\ Dir/Pkg/Sources/My\\ Lib/B\\'s.swift (in target 'Lib' from project 'Lib')
            """
        #expect(CompiledFiles.parse(log) == ["/P/Space Dir/Pkg/Sources/My Lib/A file.swift", "/P/Space Dir/Pkg/Sources/My Lib/B's.swift"])
    }

    /// Only the kinds of source file whose compiling the log shows are kept. Of a `CompileC` line, the object file is
    /// the first word and the source the second.
    @Test func onlySourceFilesThatAreCompiledAreKept() {
        let log = """
            CompileC /T/Obj.o /P/Sources/Obj/Obj.mm normal arm64 objective-c++ com.apple.compiler (in target 'Obj' from project 'Lib')
            CompileC /T/c.o /P/Sources/C/c.c normal arm64 c com.apple.compiler (in target 'C' from project 'Lib')
            CompileC /T/k.o /P/Sources/K/k.cpp normal arm64 c++ com.apple.compiler (in target 'K' from project 'Lib')
            CompileC /T/k.o /P/Sources/K/k.cc normal arm64 c++ com.apple.compiler (in target 'K' from project 'Lib')
            CompileC /T/k.o /P/Sources/K/k.cxx normal arm64 c++ com.apple.compiler (in target 'K' from project 'Lib')
            CompileC /T/s.o /P/Sources/S/s.s normal arm64 assembler-with-cpp com.apple.compiler (in target 'S' from project 'Lib')
            CompileMetalFile /P/Sources/App/Shaders.metal (in target 'App' from project 'App')
            CompileAssetCatalog /T/App.app /P/Sources/App/Assets.xcassets (in target 'App' from project 'App')
            """
        #expect(CompiledFiles.parse(log) == ["/P/Sources/Obj/Obj.mm", "/P/Sources/C/c.c", "/P/Sources/K/k.cpp", "/P/Sources/K/k.cc",
                                             "/P/Sources/K/k.cxx"])
        #expect(CompiledFiles.isKept("/P/A.swift") && !CompiledFiles.isKept("/P/A.h") && !CompiledFiles.isKept("/P/Main.storyboard"))
    }

    /// A large project's clean build names tens of thousands of files, each on a line of its own.
    @Test func aLogOfManyThousandFilesIsReadWhole() {
        let lines = (1...30_000).map { "SwiftCompile normal arm64 /P/Big\\ App/Sources/F\($0).swift (in target 'App' from project 'App')" }
        let files = CompiledFiles.parse((["Ld /T/App normal (in target 'App' from project 'App')"] + lines).joined(separator: "\n") + "\n")
        #expect(files.count == 30_000 && files.contains("/P/Big App/Sources/F30000.swift"))
    }

    @Test func aBuildThatCompilesNothingNamesNoFile() {
        #expect(CompiledFiles.parse("Ld /T/App normal (in target 'App' from project 'App')\n** BUILD SUCCEEDED **\n").isEmpty)
        #expect(CompiledFiles.parse("").isEmpty)
    }
}
