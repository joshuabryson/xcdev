import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

/// How a Mac app is started.
@Suite struct MacAppHostTests {
    let fake = FakeProcessRunner()
    let product = AppProduct(path: "/tmp/x/Mac.app", bundleId: "dev.x.Mac", executableName: "Mac", platform: "macosx")

    func host(show: Bool = false) -> MacAppHost { MacAppHost(runner: fake, sleep: Instant.sleep).showing(show) }
    /// `ps` lists nothing before the launch and `pids` after it, as the real one does.
    func stubRunning(_ pids: [Int32]) {
        let calls = Shared(0)
        fake.stub(["ps"]) { [product] _ in
            calls.set(calls.value + 1)
            return ProcessOutput(stdout: calls.value == 1 ? "" : pids.map { "  \($0) \(product.executablePath)\n" }.joined())
        }
        fake.stub(["open"])
    }

    @Test func aLaunchIsHiddenInTheBackgroundWithAppNapOff() async throws {
        stubRunning([7])
        let pid = try await host().launch(product, arguments: ["-resetOnboarding", "YES"], environment: [:], logFile: "/tmp/x/app.log")
        let open = try #require(fake.calls.first { $0.executable == "/usr/bin/open" })
        #expect(pid == 7 && open.arguments.prefix(3) == ["-n", "-g", "-j"])
        let args = open.arguments.drop { $0 != "--args" }.dropFirst()
        #expect(Array(args) == ["-NSAppSleepDisabled", "YES", "-resetOnboarding", "YES"])
    }

    @Test func showLaunchesVisibleAndInFrontAndSaysSo() async throws {
        stubRunning([7])
        let notes = Notes()
        try await Notes.$current.withValue(notes) {
            _ = try await host(show: true).launch(product, arguments: [], environment: [:], logFile: "/tmp/x/app.log")
        }
        let open = try #require(fake.calls.first { $0.executable == "/usr/bin/open" })
        #expect(!open.arguments.contains("-g") && !open.arguments.contains("-j") && open.arguments.first == "-n")
        #expect(notes.all == ["shown and brought to the front at your request"])
    }

    /// With `--show` the launch drops `-g -j` and adds nothing; the preset's own arguments pass through.
    @Test func aShownLaunchAddsNoArgumentsOfItsOwn() async throws {
        stubRunning([7])
        _ = try await host(show: true).launch(product, arguments: [], environment: [:], logFile: "/tmp/x/app.log")
        let bare = try #require(fake.calls.first { $0.executable == "/usr/bin/open" })
        #expect(!bare.arguments.contains("--args"))
        _ = try await host(show: true).launch(product, arguments: ["-flag"], environment: [:], logFile: "/tmp/x/app.log")
        let preset = try #require(fake.calls.last { $0.executable == "/usr/bin/open" })
        #expect(Array(preset.arguments.drop { $0 != "--args" }) == ["--args", "-flag"])
    }

    @Test func anAppNapArgumentFromThePresetIsNotDoubled() async throws {
        stubRunning([7])
        _ = try await host().launch(product, arguments: ["-NSAppSleepDisabled", "NO"], environment: [:], logFile: "/tmp/x/app.log")
        let open = try #require(fake.calls.first { $0.executable == "/usr/bin/open" })
        #expect(open.arguments.filter { $0 == "-NSAppSleepDisabled" }.count == 1 && open.arguments.last == "NO")
    }
}
