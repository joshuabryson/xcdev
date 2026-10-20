import Testing
@testable import XcdevKit

/// The words of `xcd sim fold`.
@Suite struct PostureTests {
    @Test func eachPostureIsAnAngleAndASpringBoardWord() {
        #expect(Posture.closed.degrees == 0 && Posture.half.degrees == 90 && Posture.open.degrees == 180)
        #expect(Posture.closed.springBoardState == "fullyClosed")
        #expect(Posture.half.springBoardState == "partiallyOpen")
        #expect(Posture.open.springBoardState == "openFlat")
    }

    @Test func theNearestPostureSplitsAt45And135Degrees() {
        #expect(Posture.nearest(0) == .closed && Posture.nearest(44.9) == .closed)
        #expect(Posture.nearest(45) == .half && Posture.nearest(134.9) == .half)
        #expect(Posture.nearest(135) == .open && Posture.nearest(180) == .open)
    }

    @Test func aSpringBoardStateWordWithASuffixNamesItsPosture() {
        #expect(Posture(springBoardState: "openFlat") == .open)
        #expect(Posture(springBoardState: "partiallyOpen+toClosed") == .half)
        #expect(Posture(springBoardState: "partiallyOpen+foldAvoidance") == .half)
        #expect(Posture(springBoardState: "fullyClosed") == .closed)
        #expect(Posture(springBoardState: "tent") == nil)
    }

    @Test func foldOptionsParseTheWordsAndTheAngle() throws {
        let open = try FoldOptions.parse(posture: "open", angle: nil, route: nil, device: "duo")
        #expect(open.request == .hinge(degrees: 180) && open.device == "duo" && open.route == nil)
        let angle = try FoldOptions.parse(posture: nil, angle: 120, route: "direct", device: nil)
        #expect(angle.request == .hinge(degrees: 120) && angle.route == .direct)
        let report = try FoldOptions.parse(posture: nil, angle: nil, route: nil, device: nil)
        #expect(report.request == nil)
    }

    @Test func foldOptionsRefuseBadWordsAnglesAndRoutes() {
        let word = #expect(throws: XcdError.self) { try FoldOptions.parse(posture: "tent", angle: nil, route: nil, device: nil) }
        #expect(word?.code == .usage && word?.next == "use one of: closed, half, open, or --angle <degrees>")
        let both = #expect(throws: XcdError.self) { try FoldOptions.parse(posture: "open", angle: 90, route: nil, device: nil) }
        #expect(both?.message == "a posture and --angle can't be combined")
        let range = #expect(throws: XcdError.self) { try FoldOptions.parse(posture: nil, angle: 190, route: nil, device: nil) }
        #expect(range?.code == .usage && range?.next == "0 is closed, 90 half open, 180 open flat")
        let route = #expect(throws: XcdError.self) { try FoldOptions.parse(posture: nil, angle: nil, route: "carrier-pigeon", device: nil) }
        #expect(route?.code == .usage && route?.next == "use one of: direct")
    }

    @Test func aStateSaysWhetherItAlreadySatisfiesARequest() {
        let closed = PostureState(innerActive: false, degrees: 0, posture: .closed, orientation: .portrait)
        #expect(closed.satisfies(.hinge(degrees: 0)) && !closed.satisfies(.hinge(degrees: 180)))
        #expect(closed.satisfies(.orientation(.portrait)) && !closed.satisfies(.orientation(.landscapeLeft)))
        let open = PostureState(innerActive: true, degrees: 180, posture: .open, orientation: .portrait)
        #expect(open.satisfies(.hinge(degrees: 180)) && open.satisfies(.hinge(degrees: 179.5)) && !open.satisfies(.hinge(degrees: 170)))
        // Closed with no line of this boot: the cover being active is proof enough for 0°, and for nothing else.
        let unknownAngle = PostureState(innerActive: false, degrees: nil, posture: nil, orientation: nil)
        #expect(unknownAngle.satisfies(.hinge(degrees: 0)) && !unknownAngle.satisfies(.hinge(degrees: 10)))
        #expect(!unknownAngle.satisfies(.orientation(.portrait)))
        #expect(unknownAngle.postureText == "closed" && unknownAngle.display == "cover")
        #expect(PostureState(innerActive: true).postureText == "open or half")
        #expect(PostureState(innerActive: true, posture: .half).display == "inner")
        // With a known angle the 1° rule decides, even on the cover, which the Duo keeps on at 61.7°; and the angle names
        // its nearest posture when the line's state word is none of the three.
        #expect(PostureState(innerActive: false, degrees: 61.7).satisfies(.hinge(degrees: 0)) == false)
        #expect(PostureState(innerActive: false, degrees: 61.7).postureText == "half")
    }

    @Test func postureFailedIsAnEnvironmentFailure() {
        #expect(ErrorCode.postureFailed.rawValue == "posture_failed")
        #expect(ErrorCode.postureFailed.exitCode == 3)
        #expect(ErrorCode.platformUnsupported.summary.contains("hinge"))
        #expect(ErrorCode.configInvalid.summary.contains("posture recipe"))
    }
}
