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
