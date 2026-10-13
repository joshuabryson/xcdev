import Foundation
import Testing
import XcdevTestSupport
@testable import XcdevKit

@Suite struct ServicesTests {
    @Test func servicesShareOneDetachedLauncher() {
        let detached = FakeDetachedProcesses()
        let services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                                environment: [:], detached: detached)
        #expect(services.media.detached as? FakeDetachedProcesses === detached)
        #expect(services.worktrees.detached as? FakeDetachedProcesses === detached)
        #expect(services.doctor.detached as? FakeDetachedProcesses === detached)
        #expect(services.media.currentDirectory == "/cwd")
    }

    /// `xcd lint` reads paths from where it is run, and looks for the linter in this process's PATH first. Its
    /// scratch folders are registered with the handler Ctrl-C fires, or they would be left behind.
    @Test func lintGetsTheCurrentDirectoryThePathAndTheOutputFormat() {
        let services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                                environment: ["PATH": "/custom/bin:/usr/bin"], output: .json, interrupts: Interrupts())
        let host = services.lint.host
        #expect(host.currentDirectory == "/cwd" && host.output == .json)
        #expect(host.interrupts === services.interrupts)
        #expect(host.locator.folders == ["/custom/bin", "/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(services.setup.locator.folders == host.locator.folders)                // `init` says whether the linter is installed
        #expect(host.targets.currentDirectory == "/cwd")
    }

    @Test func uiServicesShareTheLauncherAndTransport() {
        let detached = FakeDetachedProcesses()
        let transport = FakeRunnerTransport()
        let services = Services(runner: FakeProcessRunner(), globalPaths: GlobalPaths(base: "/h"), currentDirectory: "/cwd",
                                environment: [:], detached: detached, runnerTransport: transport)
        #expect(services.runners.detached as? FakeDetachedProcesses === detached)
        #expect(services.ui.client.transport as? FakeRunnerTransport === transport)
        #expect(services.runners.client.transport as? FakeRunnerTransport === transport)
        #expect(services.ui.supervisor.client.transport as? FakeRunnerTransport === transport)
        #expect(services.runnerBuilder.globalPaths == GlobalPaths(base: "/h"))
    }
}
