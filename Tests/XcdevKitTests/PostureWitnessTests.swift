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

    /// A hinge change merged into a running display transition shows only in the transition's `COMPLETED:` line, whose
    /// angle and state follow a `|`. Taken from a Duo clone's log, 2026-10-19.
    @Test func aCompletedLineGivesTheAngleTheTransitionEndedAt() throws {
        let line = try #require(PoseLine.parse(
            "2026-10-19 18:22:22.535 Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DisplayContentMode] COMPLETED:     .inner:pri .cover:aux | 90.0° (0.50 fold:1.00): partiallyOpen+foldAvoidance [device:Pu]"))
        #expect(line.degrees == 90 && line.posture == .half && line.state == "partiallyOpen+foldAvoidance")
        #expect(line.timestamp == PoseLine.timestamp("2026-10-19 18:22:22.535"))
    }

    /// A `COMPLETED:` line names the display the transition left primary; a `DCMPose` line names none. Taken from an
    /// iOS 27.2 Duo clone's log, 2026-11-11.
    @Test func aCompletedLineNamesTheDisplayItLeftPrimary() throws {
        let opened = try #require(PoseLine.parse(
            "2026-11-11 12:00:17.682 Df SpringBoard[76252:2a18ad2] [com.apple.SpringBoard:DisplayContentMode] COMPLETED:     .cover:aux .inner:pri | 180.0° (1.00 fold:1.00): openFlat [device:Pu]"))
        let closed = try #require(PoseLine.parse(
            "2026-11-11 11:58:50.395 Df SpringBoard[74543:2a16296] [com.apple.SpringBoard:DisplayContentMode] COMPLETED:     .cover:pri .inner:off | 0.0° (0.00 fold:0.00): fullyClosed [device:Pu]"))
        let pose = try #require(PoseLine.parse(
            "2026-11-11 12:00:29.973 Df SpringBoard[76252:2a18ad2] [com.apple.SpringBoard:DevicePose] DCMPose: 87.4° (0.49 fold:1.00): partiallyOpen+foldAvoidance [device:Pu]"))
        #expect(opened.innerPrimary == true && closed.innerPrimary == false && pose.innerPrimary == nil)
    }

    /// The transition's other lines carry an angle after a `|` too, but say where it started, not where it ended.
    @Test func startingAndResolvedLinesAreNotHingeLines() {
        #expect(PoseLine.parse("2026-10-19 18:22:21.105 Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DisplayContentMode] STARTING:      .inner:off→pri .cover:pri→aux | style .continuousSnapshot | 180.0° (1.00 fold:1.00): openFlat [device:Pu]") == nil)
        #expect(PoseLine.parse("2026-10-19 18:22:21.104 Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DisplayContentMode] DCMResolved: FullyClosed→FoldingDual | EE068395-1168-4EAC-893E-5DC96E43201E: target off→pri, resolved off→pri | 7F831870-EE1C-4FAE-A418-04E9F7109271: target pri→aux, resolved pri→aux") == nil)
    }

    /// SpringBoard's orientation update while closed, from a Duo clone's log, 2026-10-19.
    @Test func anOrientationUpdateGivesTheTimeAndTheDevicesOrientation() throws {
        let line = try #require(OrientationLine.parse(
            "2026-10-19 19:42:40.438 Df SpringBoard[88269:1063c187] [com.apple.SpringBoard:DeviceOrientationUpdateDeferral] Updated device orientation update to: landscapeLeft (3) animated: YES for reason: Device pose changed (surfaceType: .cover currentPose: 0.0° (0.00 fold:0.00): fullyClosed [device:Ll inner:Pu])"))
        #expect(line.word == "landscapeLeft" && line.orientation == .landscapeLeft)
        #expect(line.timestamp == PoseLine.timestamp("2026-10-19 19:42:40.438"))
    }

    /// While open, the update names the device's own orientation, not devicectl's quarter-turned word, which said
    /// `portraitUpsideDown` at that moment.
    @Test func anOpenOrientationUpdateIsTheDevicesOwnWordAndTheOrderIsKept() {
        let lines = OrientationLine.parseAll(Fixture.string("springboard-orientation.log"))
        #expect(lines.map(\.word) == ["landscapeLeft", "landscapeRight"])
        #expect(lines.map(\.orientation) == [.landscapeLeft, .landscapeRight])
        #expect(OrientationLine(timestamp: Date(), word: "faceUp").orientation == nil)
    }

    /// A hinge line is not an orientation update, a deferred update is not one either, and an update is not a hinge line.
    @Test func orientationUpdatesAndHingeLinesAreToldApart() {
        let fixture = Fixture.string("springboard-devicepose.log")
        #expect(OrientationLine.parseAll(fixture).isEmpty)
        #expect(PoseLine.parseAll(Fixture.string("springboard-orientation.log")).isEmpty)
        #expect(OrientationLine.parse("2026-10-19 19:37:09.595 Df SpringBoard[81258:112e4005] [com.apple.SpringBoard:DeviceOrientationUpdateDeferral] Deferred device orientation update to: portrait (1) animated: YES for reason: Device orientation update deferral state changed (surfaceType: .cover currentPose: 0.0° (0.00 fold:0.00): fullyClosed [device:Pu])") == nil)
    }

    @Test func otherLinesAreSkippedAndTheOrderIsKept() {
        let lines = PoseLine.parseAll(Fixture.string("springboard-devicepose.log"))
        #expect(lines.map(\.degrees) == [90, 90, 0, 180, 180, 90])
        #expect(lines.map(\.posture) == [.half, .half, .closed, .open, .open, .half])
        #expect(PoseLine.parse("2026-10-17 19:59:54.886 Df SpringBoard[88269:106d3677] [com.apple.SpringBoard:DevicePose] CMMagicPose surface orientation changed: cover Po -> Ll, inner Am -> Am") == nil)
        #expect(PoseLine.parse("Timestamp               Ty Process[PID:TID]") == nil)
    }
}
