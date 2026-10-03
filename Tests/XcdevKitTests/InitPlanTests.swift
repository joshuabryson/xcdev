import Foundation
import Testing
@testable import XcdevKit

@Suite struct InitPlanTests {
    let catalog = try! SimCatalog.decode(Data(Fixture.string("simctl-list-init.json").utf8))
    let xcode = XcodeInstall(path: "/Applications/Xcode.app", version: "27.0", build: "27A266a")
    /// The recorded iOS app with an embedded watch app (see ProjectDetectionTests).
    static let watchApp = DetectedProject(container: "SampleApp.xcodeproj", kind: .project,
                                          schemes: ["SampleApp", "SampleWatch Watch App"], appSchemes: ["SampleApp"],
                                          testSchemes: ["SampleApp"], platforms: [.iOS, .watchOS], deviceFamilies: [1, 2])
    static let package = DetectedProject(container: "Package.swift", kind: .package, schemes: ["SamplePackage"],
                                         appSchemes: ["SamplePackage"], testSchemes: ["SamplePackage"],
                                         platforms: [.iOS, .macOS], deviceFamilies: [])

    func plan(_ detected: DetectedProject, containers: [String] = []) -> InitPlan {
        InitPlanner.plan(detected: detected, containers: containers.isEmpty ? [detected.container] : containers,
                         folder: "SampleApp", catalog: catalog, xcodes: [xcode], selected: xcode)
    }

    @Test func devicesKeepSimctlsNewestFirstOrderWithVariantsLast() {
        let iphone = DeviceSuggestions.choices(for: .iphone, catalog: catalog)
        #expect(iphone.types == ["iPhone 18 Pro", "iPhone 18 Pro Max", "iPhone 17 Pro", "iPhone 17e", "iPhone Air"])
        #expect(iphone.runtime == "iOS 27.0")
        #expect(DeviceSuggestions.choices(for: .ipad, catalog: catalog).types
                == ["iPad Pro 13-inch (M5)", "iPad Pro 11-inch (M5)", "iPad Air 11-inch (M4)", "iPad (A16)", "iPad mini (A17 Pro)"])
        #expect(DeviceSuggestions.choices(for: .watch, catalog: catalog).types.first == "Apple Watch Series 12 (46mm)")
        // visionOS 27.0 supports only one of the two Vision Pro types.
        #expect(DeviceSuggestions.choices(for: .vision, catalog: catalog).types == ["Apple Vision Pro"])
        // No tvOS runtime is installed: every Apple TV type is offered, with no runtime.
        let tv = DeviceSuggestions.choices(for: .tv, catalog: catalog)
        #expect(tv.runtime == nil && tv.types == ["Apple TV 4K (3rd generation)", "Apple TV 4K (3rd generation) (at 1080p)"])
    }

    @Test func onlyDecisionsThatApplyAreAsked() {
        let plan = plan(Self.watchApp)
        #expect(plan.primary == .iphone)
        #expect(plan.decisions.map(\.key) == ["devices.default", "devices.ipad", "devices.watch", "xcode"])
        let watch = plan.decisions[2]
        #expect(watch.recommended == "Apple Watch Series 12 (46mm)" && watch.options.last == "none")
        #expect(watch.ask == "Your app has a watchOS app. Should each worktree also get a paired Apple Watch, and which one?")
        let ipad = plan.decisions[1]
        #expect(ipad.recommended == "iPad Pro 13-inch (M5)" && ipad.options.last == "none")
        #expect(ipad.reason == "your app runs on iPad, and xcd clones it only for commands that use `--device ipad`")
        #expect(!plan.decisions.contains { $0.key == "devices.tv" || $0.key == "project" || $0.key == "schemes.app" })
    }

    @Test func planText() {
        let report = InitPlanReport(plan: plan(Self.watchApp), root: "/w", configExists: false)
        #expect(report.text == """
        detected: SampleApp.xcodeproj, schemes=[SampleApp, SampleWatch Watch App], platforms=[iOS, watchOS]
        xcode: 27.0 (only install)

        decision devices.default
          ask: "Which iPhone should agents build and test on by default?"
          options: iPhone 18 Pro (recommended: newest installed (iOS 27.0)), iPhone 18 Pro Max, iPhone 17 Pro, iPhone 17e, iPhone Air

        decision devices.ipad
          ask: "Your app also runs on iPad. Should each worktree also get an iPad simulator, and which one?"
          options: iPad Pro 13-inch (M5) (recommended: your app runs on iPad, and xcd clones it only for commands that use `--device ipad`), iPad Pro 11-inch (M5), iPad Air 11-inch (M4), iPad (A16), iPad mini (A17 Pro), none

        decision devices.watch
          ask: "Your app has a watchOS app. Should each worktree also get a paired Apple Watch, and which one?"
          options: Apple Watch Series 12 (46mm) (recommended: the watch app runs only on an Apple Watch paired with the iPhone), Apple Watch Series 12 (42mm), Apple Watch Ultra 4 (49mm), Apple Watch Series 11 (46mm), Apple Watch SE 3 (44mm), none

        decision xcode
          ask: "Pin a specific Xcode version, or use whatever is selected on this Mac?"
          options: system (recommended: it follows xcode-select, so updating Xcode needs no config change), 27.0
        next: ask the user each decision, then run `xcd init --set <key>=<value> …`, or `xcd init --defaults`
        """)
    }

    @Test func defaultsWriteTheRecommendations() throws {
        let generated = try plan(Self.watchApp).config(answers: [:])
        #expect(generated.yaml == """
        # xcdev project configuration, written by `xcd init`.
        # Explain any key with `xcd config explain <key>`; walkthrough: `xcd guide setup`.
        version: 1
        project: "SampleApp.xcodeproj"
        schemes:
          app: "SampleApp"
          test: "SampleApp"
        defaultDevice: iphone
        devices:
          iphone: { type: "iPhone 18 Pro", runtime: latest }
          ipad: { type: "iPad Pro 13-inch (M5)", runtime: latest }
          watch: { type: "Apple Watch Series 12 (46mm)", runtime: latest, pairWith: iphone }

        """)
        #expect(generated.summary == [
            "project: SampleApp.xcodeproj", "schemes: app=SampleApp test=SampleApp",
            "devices: iphone=iPhone 18 Pro (default), ipad=iPad Pro 13-inch (M5), "
                + "watch=Apple Watch Series 12 (46mm) (paired with iphone)",
            "xcode: system (the Xcode xcode-select points to)",
        ])
    }

    @Test func answersOverrideRecommendations() throws {
        let generated = try plan(Self.watchApp).config(answers: ["devices.default": "iphone 17 pro", "devices.ipad": "yes",
                                                                 "devices.watch": "no", "xcode": "27.0"])
        let config = try ConfigLoader.parse(main: generated.yaml)
        #expect(config.xcode == "27.0")
        #expect(config.allDevices["iphone"]?.type == "iPhone 17 Pro")
        #expect(config.allDevices["ipad"]?.type == "iPad Pro 13-inch (M5)")
        #expect(config.allDevices["watch"] == nil)
    }

    @Test func badAnswersAreConfigInvalidWithASuggestion() {
        let plan = plan(Self.watchApp)
        let typo = #expect(throws: XcdError.self) { try plan.config(answers: ["devices.wach": "none"]) }
        #expect(typo?.code == .configInvalid)
        #expect(typo?.next == "did you mean 'devices.watch'? `xcd init --plan` lists this project's decisions")
        let notHere = #expect(throws: XcdError.self) { try plan.config(answers: ["devices.tv": "none"]) }
        #expect(notHere?.message == "devices.tv does not apply to this project")
        let value = #expect(throws: XcdError.self) { try plan.config(answers: ["xcode": "26.4"]) }
        #expect(value?.message == "'26.4' is not an option for xcode")
        #expect(value?.next == "use one of: system, 27.0")
    }

    @Test func aPackageBuildsOnTheMacUnlessASimulatorIsAdded() throws {
        let plan = plan(Self.package)
        #expect(plan.primary == nil)
        #expect(plan.decisions.map(\.key) == ["devices.iphone", "xcode"])
        let host = try plan.config(answers: [:])
        #expect(!host.yaml.contains("devices:"))
        #expect(host.summary.contains("devices: none (the package builds and tests on this Mac)"))
        let config = try ConfigLoader.parse(main: try plan.config(answers: ["devices.iphone": "yes"]).yaml)
        #expect(config.defaultDevice == "mac")
        #expect(config.allDevices["mac"]?.isMac == true && config.allDevices["iphone"]?.type == "iPhone 18 Pro")
    }

    @Test func aSimulatorOnlyPackageDefaultsToTheIPhoneAndLeavesTheWatchOptional() {
        let package = DetectedProject(container: "Package.swift", kind: .package, schemes: ["A", "B", "Multi Lib-Package"],
                                      appSchemes: ["Multi Lib-Package", "A", "B"], testSchemes: ["Multi Lib-Package", "A", "B"],
                                      platforms: [.iOS, .watchOS], deviceFamilies: [])
        let plan = plan(package)
        #expect(plan.primary == .iphone)
        let watch = plan.decisions.first { $0.key == "devices.watch" }
        #expect(watch?.recommended == "none" && watch?.options.first == "none")
        #expect(watch?.reason == "add it when you test the package on Apple Watch")
        #expect(watch?.ask == "The package also supports watchOS. Should each worktree also get an Apple Watch simulator, and which one?")
        #expect(plan.decisions.first { $0.key == "schemes.test" }?.reason == "it tests every target of the package")
    }

    @Test func severalProjectsAndAMacAppAreDecisions() {
        let mac = DetectedProject(container: "SampleApp.xcworkspace", kind: .workspace, schemes: ["SampleApp", "Admin"],
                                  appSchemes: ["SampleApp", "Admin"], testSchemes: ["SampleAppTests", "SampleApp"],
                                  platforms: [.iOS, .macOS], deviceFamilies: [1])
        let plan = plan(mac, containers: ["SampleApp.xcworkspace", "Admin.xcworkspace"])
        #expect(plan.decisions.map(\.key) == ["project", "schemes.app", "schemes.test", "devices.default", "devices.mac", "xcode"])
        #expect(plan.decisions[0].reason == "it is named like the folder")
        #expect(plan.decisions.first { $0.key == "devices.mac" }?.recommended == "yes")
        #expect(plan.decisions[1].reason == "it builds an app and is named like the project")
        var unnamed = mac
        unnamed.appSchemes = ["Admin", "Shop"]
        #expect(self.plan(unnamed).decisions.first { $0.key == "schemes.app" }?.reason
                == "it builds an app and comes first alphabetically")
    }

    @Test func aPlatformWithNoRuntimeSaysHowToDownloadIt() {
        let tvApp = DetectedProject(container: "SampleApp.xcodeproj", kind: .project, schemes: ["SampleApp"],
                                    appSchemes: ["SampleApp"], testSchemes: ["SampleApp"],
                                    platforms: [.iOS, .tvOS], deviceFamilies: [1, 3])
        let plan = plan(tvApp)
        #expect(plan.notes == ["no tvOS simulator runtime is installed; run `xcodebuild -downloadPlatform tvOS` before using that device"])
        let tv = plan.decisions.first { $0.key == "devices.tv" }
        #expect(tv?.recommended == "none" && tv?.reason == "no tvOS simulator runtime is installed yet")
        #expect(tv?.options == ["none", "Apple TV 4K (3rd generation)", "Apple TV 4K (3rd generation) (at 1080p)"])
        let report = InitPlanReport(plan: plan, root: "/w", configExists: false)
        #expect(report.text.contains("\n\nnote: no tvOS simulator runtime is installed; run `xcodebuild -downloadPlatform tvOS` before using that device\nnext: "))
    }

    @Test func anAppsExtraDeviceWithARuntimeIsRecommended() {
        let visionApp = DetectedProject(container: "SampleApp.xcodeproj", kind: .project, schemes: ["SampleApp"],
                                        appSchemes: ["SampleApp"], testSchemes: ["SampleApp"],
                                        platforms: [.iOS, .visionOS], deviceFamilies: [1, 7])
        let vision = plan(visionApp).decisions.first { $0.key == "devices.vision" }
        #expect(vision?.recommended == "Apple Vision Pro" && vision?.options == ["Apple Vision Pro", "none"])
        #expect(vision?.reason == "your app runs on Apple Vision Pro, and xcd clones it only for commands that use `--device vision`")
    }

    @Test func detectionNotesReachThePlanAndExplainMissingPlatforms() {
        let unread = "could not read the build settings of scheme \"SampleApp\" (`xcrun xcodebuild -showBuildSettings` "
            + "did not finish within 2m), so its platforms are not included"
        // Every scheme failed: the detection note says why there are no platforms, so no generic guess is added.
        var failed = DetectedProject(container: "SampleApp.xcodeproj", kind: .project, schemes: ["SampleApp"],
                                     appSchemes: [], testSchemes: [], platforms: [], deviceFamilies: [])
        failed.notes = [unread]
        let failedPlan = plan(failed)
        #expect(failedPlan.primary == .iphone)
        #expect(failedPlan.notes == [unread, "no scheme builds an app; set schemes.app in .xcdev.yml to the scheme `xcd build` should use"])
        // With no detection note, the plan says what it assumed.
        failed.notes = []
        #expect(plan(failed).notes.contains(
            "no target reported its platforms, so this assumes an iOS app; change devices in .xcdev.yml if that's wrong"))
        // A detection note on a project with platforms is carried through first.
        var partial = Self.watchApp
        partial.notes = ["read the build settings of 12 of 16 schemes; not read: A, B, C, D"]
        #expect(plan(partial).notes == partial.notes)
        #expect(InitPlanReport(plan: plan(partial), root: "/w", configExists: false).text
                .contains("note: read the build settings of 12 of 16 schemes; not read: A, B, C, D"))
    }
}
