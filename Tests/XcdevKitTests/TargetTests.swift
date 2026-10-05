import Foundation
import Testing
@testable import XcdevKit

@Suite struct TargetTests {
    @Test func parsesEveryForm() {
        #expect(TargetParser.parse("id:signIn") == .success(.id("signIn")))
        #expect(TargetParser.parse("label:Sign In") == .success(.label("Sign In")))
        #expect(TargetParser.parse("label~welc") == .success(.labelContains("welc")))
        #expect(TargetParser.parse("ref:e12") == .success(.ref("e12")))
        #expect(TargetParser.parse("@120,300.5") == .success(.point(x: 120, y: 300.5)))
        #expect(TargetParser.parse("label:a:b") == .success(.label("a:b")))          // only the first colon splits
    }

    @Test func rejectsWhatIsNotATarget() {
        for bad in ["signIn", "id:", "label:", "label~", "ref:12", "ref:e", "@1", "@a,b", "@1,2,3", ""] {
            guard case .failure(let failure) = TargetParser.parse(bad) else {
                Issue.record("'\(bad)' parsed")
                continue
            }
            #expect(failure.message.contains("is not a target"))
        }
        #expect(TargetParser.forms == "id:<identifier>, label:<text>, label~<part of the label>, ref:e<N> (from `xcd ui tree`), or @x,y")
    }

    func nodes() -> [FlatNode] {
        var nodes: [FlatNode] = []
        TreeBuilder.flatten(TreeBuilderTests.app, source: .app, into: &nodes)
        return nodes
    }

    @Test func matchesByIdentifierLabelAndPartOfALabel() {
        let all = nodes()
        #expect(TargetMatcher.match(.id("email"), role: nil, index: nil, in: all, refs: [:]) == .one(5))
        #expect(TargetMatcher.match(.label("Welcome back"), role: nil, index: nil, in: all, refs: [:]) == .one(6))
        #expect(TargetMatcher.match(.labelContains("WELCOME"), role: nil, index: nil, in: all, refs: [:]) == .one(6))
        #expect(TargetMatcher.match(.id("nope"), role: nil, index: nil, in: all, refs: [:]) == .none)
        #expect(TargetMatcher.match(.label("SampleApp"), role: nil, index: nil, in: all, refs: [:]) == .none)   // not the application
    }

    @Test func aLabelSharedWithAnAncestorIsOneMatch() {
        // The button "Sign In" (3) contains the text "Sign In" (4): the button is the match.
        #expect(TargetMatcher.match(.label("Sign In"), role: nil, index: nil, in: nodes(), refs: [:]) == .one(3))
        // Asking for the text by role still finds it.
        #expect(TargetMatcher.match(.label("Sign In"), role: "text", index: nil, in: nodes(), refs: [:]) == .one(4))
    }

    @Test func severalMatchesAreAmbiguousUnlessAnIndexPicksOne() {
        var two: [FlatNode] = []
        let row = { (y: Double) in TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 0, y: y, w: 100, h: 40)) }
        TreeBuilder.flatten(TreeBuilderTests.node(2, frame: TreeBuilderTests.screen, [row(100), row(200)]), source: .app, into: &two)
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: nil, in: two, refs: [:]) == .ambiguous([1, 2]))
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: 1, in: two, refs: [:]) == .one(2))
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: 5, in: two, refs: [:]) == .none)
    }

    @Test func aRefFindsTheSameElementAgainOrIsStale() {
        let all = nodes()
        let refs = ["e1": all[3].signature, "e2": all[8].signature]
        #expect(TargetMatcher.match(.ref("e1"), role: nil, index: nil, in: all, refs: refs) == .one(3))
        #expect(TargetMatcher.match(.ref("e2"), role: nil, index: nil, in: all, refs: refs) == .one(8))
        #expect(TargetMatcher.match(.ref("e9"), role: nil, index: nil, in: all, refs: refs) == .staleRef)       // unknown ref
        var changed = all
        changed[3].signature.label = "Sign Out"                                                                  // the element changed
        #expect(TargetMatcher.match(.ref("e1"), role: nil, index: nil, in: changed, refs: refs) == .staleRef)
    }

    @Test func targetsRoundTripThroughJSON() throws {
        for target in [TargetSpec.id("a"), .label("b"), .labelContains("c"), .ref("e1"), .point(x: 1.5, y: 2)] {
            #expect(try JSONDecoder().decode(TargetSpec.self, from: JSONEncoder().encode(target)) == target)
        }
    }
}
