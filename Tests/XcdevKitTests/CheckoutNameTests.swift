import Testing
@testable import XcdevKit

/// The name xcd gives a checkout it did not make.
@Suite struct CheckoutNameTests {
    @Test func aFreeValidFolderNameIsTheName() {
        #expect(CheckoutName.choose(for: "/u/.claude/worktrees/login-flow", held: ["main"]) == "login-flow")
    }

    @Test func aFolderNameAnotherCheckoutHoldsGetsItsParentInFront() {
        #expect(CheckoutName.choose(for: "/u/.codex/worktrees/a1b2/pkg", held: ["main", "pkg"]) == "a1b2-pkg")
        #expect(CheckoutName.choose(for: "/w/Pkg", held: ["pkg"]) == "w-Pkg")
        #expect(CheckoutName.choose(for: "/w/Main", held: []) == "w-Main")
    }

    @Test func aHeldParentNameGetsANumber() {
        #expect(CheckoutName.choose(for: "/x/a1b2/pkg", held: ["pkg", "a1b2-pkg"]) == "a1b2-pkg-2")
        #expect(CheckoutName.choose(for: "/x/a1b2/pkg", held: ["pkg", "a1b2-pkg", "a1b2-pkg-2"]) == "a1b2-pkg-3")
    }

    @Test func aFolderNameThatIsNotAValidWorktreeNameIsMadeValid() {
        #expect(CheckoutName.choose(for: "/x/wt/main", held: []) == "wt-main")
        #expect(CheckoutName.choose(for: "/x/My Work/App Copy", held: []) == "My-Work-App-Copy")
        #expect(CheckoutName.choose(for: "/x/wt/v1..2", held: []) == "wt-v1--2")
        #expect(CheckoutName.choose(for: "/x/wt/old.lock", held: []) == "wt-old-lock")
        #expect(CheckoutName.choose(for: "/x/_tmp/.hidden", held: []) == "tmp--hidden")
        #expect(CheckoutName.choose(for: "/main", held: []) == "main-2")
        #expect(CheckoutName.choose(for: "/x/Café/pkg", held: ["pkg"]) == "Caf--pkg")
    }

    @Test func aLongNameWithANumberStaysWithinTheLimitAndPassesValidate() throws {
        let long = String(repeating: "a", count: 99)
        let name = CheckoutName.choose(for: "/x/\(long)/\(long)", held: [long, String(("\(long)-\(long)").prefix(100))])
        #expect(name.count == 100 && name.hasSuffix("-2"))
        try WorktreeService.validate(name: name)
    }

    @Test func aPathWithNothingUsableIsCalledCheckout() {
        #expect(CheckoutName.choose(for: "/__/--", held: []) == "checkout")
    }
}
