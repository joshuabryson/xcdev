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
}
