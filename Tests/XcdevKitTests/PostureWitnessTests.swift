import Foundation
import Testing
@testable import XcdevKit

/// What the two public reads say.
@Suite struct PostureWitnessTests {
    func displays(_ name: String) throws -> Data { try Data(contentsOf: Fixture.url(name)) }

    @Test func aClosedReadNamesTheCoverAndThePortraitPose() throws {
        let read = try DisplaysRead.parse(displays("devicectl-displays-closed.json"))
        #expect(read == DisplaysRead(innerActive: false, deviceOrientation: "portrait"))
        #expect(read.poseOrientation == .portrait)
    }

    @Test func anOpenReadNamesTheInnerDisplayAndTurnsTheWordAQuarter() throws {
        let read = try DisplaysRead.parse(displays("devicectl-displays-open.json"))
        #expect(read.innerActive && read.deviceOrientation == "landscapeRight")
        #expect(read.poseOrientation == .portrait)
    }

    @Test func theOrientationTableIsTheOneMeasuredInBothPostures() {
        // Closed: devicectl's word is the pose.
        #expect(DisplaysRead(innerActive: false, deviceOrientation: "portrait").poseOrientation == .portrait)
        #expect(DisplaysRead(innerActive: false, deviceOrientation: "landscapeLeft").poseOrientation == .landscapeLeft)
        #expect(DisplaysRead(innerActive: false, deviceOrientation: "landscapeRight").poseOrientation == .landscapeRight)
        // Open: the pose turned a quarter.
        #expect(DisplaysRead(innerActive: true, deviceOrientation: "landscapeRight").poseOrientation == .portrait)
        #expect(DisplaysRead(innerActive: true, deviceOrientation: "portrait").poseOrientation == .landscapeLeft)
        #expect(DisplaysRead(innerActive: true, deviceOrientation: "portraitUpsideDown").poseOrientation == .landscapeRight)
    }

    @Test func anUnknownOrMissingOrientationIsUnknownNotAnError() throws {
        #expect(DisplaysRead(innerActive: false, deviceOrientation: "faceUp").poseOrientation == nil)
        let withoutOrientation = try displays("devicectl-displays-closed.json")
        let json = try #require(String(data: withoutOrientation, encoding: .utf8))
            .replacingOccurrences(of: "\"orientation\" :", with: "\"orientationGone\" :")
        let read = try DisplaysRead.parse(Data(json.utf8))
        #expect(read == DisplaysRead(innerActive: false, deviceOrientation: ""))
        #expect(read.poseOrientation == nil)
    }

    @Test func somethingThatIsNotDevicectlOutputIsSimulatorFailed() {
        let error = #expect(throws: XcdError.self) { try DisplaysRead.parse(Data("not json".utf8)) }
        #expect(error?.code == .simulatorFailed)
        #expect(error?.message == "could not read `devicectl device info displays`")
        #expect(error?.next == "run `xcd doctor`")
    }

    @Test func aPoseLineGivesTheTimeTheAngleAndThePosture() throws {
        let line = try #require(PoseLine.parse(
            "2026-10-17 19:59:48.502 Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DevicePose] DCMPose: 180.0° (1.00 fold:1.00): openFlat [device:Pu]"))
        #expect(line.degrees == 180 && line.posture == .open && line.state == "openFlat")
        #expect(line.timestamp == PoseLine.timestamp("2026-10-17 19:59:48.502"))
    }

    @Test func aTransitionSuffixStillNamesThePosture() throws {
        let line = try #require(PoseLine.parse(
            "2026-10-17 19:57:33.931 Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DevicePose] DCMPose: 90.0° (0.50 fold:0.50): partiallyOpen+toClosed (progress:0.50 toSwap:0.94 fromSwap:0.00) [device:Pu]"))
        #expect(line.degrees == 90 && line.posture == .half && line.state == "partiallyOpen+toClosed")
    }

    @Test func otherLinesAreSkippedAndTheOrderIsKept() {
        let lines = PoseLine.parseAll(Fixture.string("springboard-devicepose.log"))
        #expect(lines.map(\.degrees) == [90, 90, 0, 180])
        #expect(lines.map(\.posture) == [.half, .half, .closed, .open])
        #expect(PoseLine.parse("2026-10-17 19:59:54.886 Df SpringBoard[88269:106d3677] [com.apple.SpringBoard:DevicePose] CMMagicPose surface orientation changed: cover Po -> Ll, inner Am -> Am") == nil)
        #expect(PoseLine.parse("Timestamp               Ty Process[PID:TID]") == nil)
    }
}
