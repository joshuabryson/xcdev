import Foundation
import Testing
@testable import XcdevKit

@Suite struct DeviceResolverTests {
    let catalog = try! SimCatalog.decode(Data(Fixture.string("simctl-list.json").utf8))

    @Test func decodesCatalogAndTagsRuntimeOnDevices() {
        #expect(catalog.deviceTypes.count == 5)
        #expect(catalog.runtimes.count == 5)
        #expect(catalog.devices.first?.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(catalog.device(udid: "4CEABB59-81A5-4060-9573-99D2BA1BA97B")?.name == "iPhone 18 Pro")
    }

    @Test func latestPicksNewestRuntimeSupportingTheType() throws {
        let r = try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 16"), catalog: catalog)
        #expect(r.runtime.name == "iOS 27.0")
        #expect(r.deviceType.identifier == "com.apple.CoreSimulator.SimDeviceType.iPhone-16")
    }

    @Test func runtimeByNameVersionOrIdentifier() throws {
        for query in ["iOS 26.5", "ios 26.5", "26.5", "com.apple.CoreSimulator.SimRuntime.iOS-26-5"] {
            let r = try DeviceResolver.resolve(name: "p", spec: DeviceSpec(type: "iphone 16", runtime: query), catalog: catalog)
            #expect(r.runtime.version == "26.5", "query \(query)")
        }
    }

    @Test func visionOSMapsToXrOSRuntimes() throws {
        let r = try DeviceResolver.resolve(name: "vision", spec: DeviceSpec(type: "Apple Vision Pro"), catalog: catalog)
        #expect(r.runtime.name == "visionOS 27.0")
    }

    @Test func unknownTypeSuggests() {
        let error = #expect(throws: XcdError.self) {
            try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 18"), catalog: catalog)
        }
        #expect(error?.code == .deviceTypeUnknown)
        #expect(error?.next == "set devices.iphone.type to one of: iPhone 16, iPhone 18 Pro, iPhone 18 Pro Max")
    }

    @Test func missingRuntimeSuggestsDownload() {
        let error = #expect(throws: XcdError.self) {
            try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 16", runtime: "iOS 19.0"), catalog: catalog)
        }
        #expect(error?.code == .runtimeMissing)
        #expect(error?.next == "xcodebuild -downloadPlatform iOS")
        #expect(error?.details.contains("installed: iOS 27.0") == true)
    }

    @Test func runtimeThatDoesNotSupportType() {
        let error = #expect(throws: XcdError.self) {
            try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 18 Pro", runtime: "iOS 26.5"), catalog: catalog)
        }
        #expect(error?.code == .runtimeMissing)
        #expect(error?.message == "iOS 26.5 does not support iPhone 18 Pro")
    }

    @Test func macDeviceHasNoSimulator() {
        let error = #expect(throws: XcdError.self) {
            try DeviceResolver.resolve(name: "mac", spec: DeviceSpec(platform: "macOS"), catalog: catalog)
        }
        #expect(error?.code == .platformUnsupported)
        #expect(error?.message == "device 'mac' is a macOS device and has no simulator")
        #expect(error?.next == "a Mac app is driven with `xcd ui …` after `xcd run --device mac`, and shown to a person with "
                + "`xcd launch --device mac --show`; for a simulator, pass --device with a simulator device")
    }

    func compatibility(iOS sdk: String) -> RuntimeCompatibility {
        RuntimeCompatibility(xcode: XcodeInstall(path: "/Applications/Xcode-26.5.app", version: "26.5", build: "26F1"),
                             sdks: SimulatorSDKs(versions: ["iOS": sdk]))
    }

    @Test func latestIsCappedAtTheXcodeSDK() throws {
        let r = try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 16"), catalog: catalog,
                                           compatibility: compatibility(iOS: "26.5"))
        #expect(r.runtime.name == "iOS 26.5")
    }

    @Test func explicitRuntimeNewerThanXcodeIsAMismatch() {
        let error = #expect(throws: XcdError.self) {
            try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 16", runtime: "iOS 27.0"),
                                       catalog: catalog, compatibility: compatibility(iOS: "26.5"))
        }
        #expect(error?.code == .xcodeRuntimeMismatch)
        #expect(error?.message == "iOS 27.0 (devices.iphone) is newer than Xcode 26.5 (26F1) supports; its newest iOS simulator SDK is 26.5")
        #expect(error?.next == "set devices.iphone.runtime to one of: iOS 18.0, iOS 26.5, or use a newer Xcode via `xcode:` or --xcode")
    }

    @Test func latestWithOnlyTooNewRuntimesIsAMismatch() {
        let error = #expect(throws: XcdError.self) {
            try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 18 Pro"), catalog: catalog,
                                       compatibility: compatibility(iOS: "26.5"))
        }
        #expect(error?.code == .xcodeRuntimeMismatch)
        #expect(error?.message.hasPrefix("iOS 27.0 (devices.iphone) is newer than Xcode 26.5") == true)
    }

    @Test func suggestedRuntimesSupportTheDeviceType() {
        let error = #expect(throws: XcdError.self) {
            try DeviceResolver.resolve(name: "iphone", spec: DeviceSpec(type: "iPhone 18 Pro", runtime: "iOS 27.0"),
                                       catalog: catalog, compatibility: compatibility(iOS: "26.5"))
        }
        #expect(error?.code == .xcodeRuntimeMismatch)
        // iOS 18.0 and 26.5 are installed and within the SDK, but neither supports iPhone 18 Pro.
        #expect(error?.next == "set `xcode:` in .xcdev.yml (or pass --xcode) to an Xcode that supports iOS 27.0")
        #expect(error?.details.isEmpty == true)
    }
}
