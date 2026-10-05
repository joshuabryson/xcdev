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
        for bad in ["signIn", "id:", "label:", "label~", "ref:12", "ref:e", "@1", "@a,b", "@1,2,3", "", "@nan,1", "@1,inf", "@infinity,2", "ref:e-1", "ref:e+1", "ref:e1.0"] {
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

    @Test func nestedInteractiveMatchesKeepTheInnermostInteractive() {
        // cell(75) "Delete" > button(9) "Delete" → the button
        var tree1: [FlatNode] = []
        TreeBuilder.flatten(
            TreeBuilderTests.node(2, frame: TreeBuilderTests.screen, [
                TreeBuilderTests.node(4, frame: TreeBuilderTests.screen, [
                    TreeBuilderTests.node(1, frame: TreeBuilderTests.screen, [
                        TreeBuilderTests.node(75, label: "Delete", frame: ScreenRect(x: 0, y: 100, w: 100, h: 40), [
                            TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 10, y: 105, w: 80, h: 30))
                        ])
                    ])
                ])
            ]),
            source: .app, into: &tree1)
        let btnIdx1 = tree1.firstIndex { $0.role == "button" && $0.label == "Delete" }!
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: nil, in: tree1, refs: [:]) == .one(btnIdx1))

        // cell "Delete" > button "Delete" > text(48) "Delete" → the button
        var tree2: [FlatNode] = []
        TreeBuilder.flatten(
            TreeBuilderTests.node(2, frame: TreeBuilderTests.screen, [
                TreeBuilderTests.node(4, frame: TreeBuilderTests.screen, [
                    TreeBuilderTests.node(1, frame: TreeBuilderTests.screen, [
                        TreeBuilderTests.node(75, label: "Delete", frame: ScreenRect(x: 0, y: 100, w: 100, h: 40), [
                            TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 10, y: 105, w: 80, h: 30), [
                                TreeBuilderTests.node(48, label: "Delete", frame: ScreenRect(x: 15, y: 110, w: 70, h: 20))
                            ])
                        ])
                    ])
                ])
            ]),
            source: .app, into: &tree2)
        let btnIdx2 = tree2.firstIndex { $0.role == "button" && $0.label == "Delete" }!
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: nil, in: tree2, refs: [:]) == .one(btnIdx2))

        // other(1) "Delete" > text(48) "Delete" (none interactive) → the outer other
        var tree3: [FlatNode] = []
        TreeBuilder.flatten(
            TreeBuilderTests.node(2, frame: TreeBuilderTests.screen, [
                TreeBuilderTests.node(4, frame: TreeBuilderTests.screen, [
                    TreeBuilderTests.node(1, label: "Delete", frame: ScreenRect(x: 0, y: 100, w: 100, h: 40), [
                        TreeBuilderTests.node(48, label: "Delete", frame: ScreenRect(x: 10, y: 105, w: 80, h: 30))
                    ])
                ])
            ]),
            source: .app, into: &tree3)
        let otherIdx = tree3.firstIndex { $0.role == "other" && $0.label == "Delete" }!
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: nil, in: tree3, refs: [:]) == .one(otherIdx))

        // button "Delete" > other "Delete" > button "Delete" (interactive, non-interactive, interactive) → the innermost button
        var tree4: [FlatNode] = []
        TreeBuilder.flatten(
            TreeBuilderTests.node(2, frame: TreeBuilderTests.screen, [
                TreeBuilderTests.node(4, frame: TreeBuilderTests.screen, [
                    TreeBuilderTests.node(1, frame: TreeBuilderTests.screen, [
                        TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 0, y: 100, w: 100, h: 40), [
                            TreeBuilderTests.node(1, label: "Delete", frame: ScreenRect(x: 10, y: 105, w: 80, h: 30), [
                                TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 15, y: 110, w: 70, h: 20))
                            ])
                        ])
                    ])
                ])
            ]),
            source: .app, into: &tree4)
        let buttons = tree4.enumerated().filter { $0.element.role == "button" && $0.element.label == "Delete" }
        let innermostBtnIdx = buttons.last!.offset
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: nil, in: tree4, refs: [:]) == .one(innermostBtnIdx))
    }

    @Test func nestedPairsInSeparateBranchesAreStillAmbiguous() {
        // Two cells each containing a "Delete" button → ambiguous, and index: 1 picks the second button.
        var two: [FlatNode] = []
        let cell = { (y: Double) in TreeBuilderTests.node(75, label: "Delete", frame: ScreenRect(x: 0, y: y, w: 100, h: 40), [
            TreeBuilderTests.node(9, label: "Delete", frame: ScreenRect(x: 10, y: y + 5, w: 80, h: 30))
        ]) }
        TreeBuilder.flatten(TreeBuilderTests.node(2, frame: TreeBuilderTests.screen, [cell(100), cell(200)]), source: .app, into: &two)
        let buttons = two.enumerated().filter { $0.element.role == "button" && $0.element.label == "Delete" }.map(\.offset)
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: nil, in: two, refs: [:]) == .ambiguous(buttons))
        #expect(TargetMatcher.match(.label("Delete"), role: nil, index: 1, in: two, refs: [:]) == .one(buttons[1]))
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
