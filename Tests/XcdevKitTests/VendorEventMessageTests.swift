import Foundation
import IOKit
import Testing
@testable import XcdevKit

/// The daemon's envelope, read back.
@Suite struct VendorEventMessageTests {
    let recipe = PostureRecipeStore.builtIn.direct[0]

    /// The payload's IOKit bytes, unserialized the way locationd reads them.
    func unserialized(_ message: xpc_object_t) throws -> [String: Any] {
        let event = try #require(xpc_dictionary_get_value(message, "payload"))
        var length = 0
        let bytes = try #require(xpc_dictionary_get_data(event, "data", &length))
        let object = IOCFUnserializeBinary(bytes.assumingMemoryBound(to: CChar.self), length, nil, 0, nil)
        return try #require(object as? [String: Any])
    }

    @Test func aHingeEventIsTheEnvelopeTheDaemonDecodes() throws {
        let message = try VendorEventMessage.build(.hinge(degrees: 180), recipe)
        #expect(xpc_dictionary_get_string(message, "messageType").map { String(cString: $0) } == "IndigoVendorDefinedEvent")
        #expect(xpc_dictionary_get_string(message, "featureIdentifier").map { String(cString: $0) }
                    == "com.apple.coredevice.feature.remote.hid.vendordefined")
        #expect(xpc_dictionary_get_bool(message, "isBarrier") == false)
        let event = try #require(xpc_dictionary_get_value(message, "payload"))
        // The daemon decodes these as UInt16 with Codable, so they must be xpc uint64, not int64.
        #expect(xpc_get_type(try #require(xpc_dictionary_get_value(event, "usagePage"))) == XPC_TYPE_UINT64)
        #expect(xpc_dictionary_get_uint64(event, "usagePage") == 0xff61)
        #expect(xpc_dictionary_get_uint64(event, "usage") == 0x5b)
        #expect(xpc_dictionary_get_uint64(event, "version") == 0)
        let payload = try unserialized(message)
        #expect(payload["provider"] as? String == "com.apple.Virtualization.VirtualMachines")
        #expect(payload["source"] as? String == "hinge-slider-control")
        #expect(payload["type"] as? String == "range")
        #expect(payload["value"] as? Double == 180)
    }

    @Test func anOrientationEventCarriesTheRecipesValue() throws {
        let message = try VendorEventMessage.build(.orientation(.landscapeLeft), recipe)
        let payload = try unserialized(message)
        #expect(payload["source"] as? String == "orientation-picker-control")
        #expect(payload["type"] as? String == "enum")
        #expect(payload["value"] as? String == "landscape-left")
    }

    @Test func anOrientationTheRecipeLacksIsPlatformUnsupportedBeforeAnythingIsSent() {
        let error = #expect(throws: XcdError.self) { try VendorEventMessage.build(.orientation(.portraitUpsideDown), recipe) }
        #expect(error?.code == .platformUnsupported)
        #expect(error?.message == "portrait-upside-down is not an orientation the foldable's pose pipeline accepts")
        #expect(error?.next == "use one of: landscape-left, landscape-right, portrait")
    }

    @Test func theRouteIsAvailableWhenCoreSimulatorAndLibxpcHaveTheirPieces() async {
        // On a Mac with Xcode, CoreSimulator loads and the two `_4sim` functions resolve. A machine
        // without Xcode has nothing to check.
        guard Disk.exists(PrivateSymbols.coreSimulator) else { return }
        let context = PostureContext(udid: "00000000-0000-0000-0000-000000000000", developerDir: "/Applications/Xcode.app/Contents/Developer",
                                     recipe: recipe)
        let route: any PostureRoute = VendorEventRoute()
        #expect(await route.availability(context) == .available)
    }
}
