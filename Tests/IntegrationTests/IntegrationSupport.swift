import Foundation
import XcdevTestSupport
@testable import XcdevKit

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
/// Simulators can't write app output under $TMPDIR, so these projects live here instead.
let testsHome = NSHomeDirectory() + "/Library/Caches/xcdev-tests"

/// Live services for `project`, with its own XCDEV_HOME so the real registry is never touched.
func services(_ project: TempProject) -> Services {
    Services(runner: SystemProcessRunner(), globalPaths: GlobalPaths(base: project.home), currentDirectory: project.root,
             environment: [:])
}

/// Runs `body`, then always (even when it throws) deletes every simulator clone of this project and the project.
/// Clones are found by name (`xcd · <project> · …`), so ones a failed step never recorded in state go too.
func withCleanup(_ project: TempProject, _ body: (Services) async throws -> Void) async throws {
    let svc = services(project)
    var failure: (any Error)?
    do { try await body(svc) } catch { failure = error }
    let simctl = SimctlClient(runner: svc.runner, developerDir: nil)
    let prefix = SimNaming.clonePrefix + URL(fileURLWithPath: project.root).lastPathComponent + " · "
    if let catalog = try? await simctl.catalog() {
        for device in catalog.devices where device.name.hasPrefix(prefix) {
            _ = try? await simctl.shutdown(udid: device.udid)
            try? await simctl.delete(udid: device.udid)
        }
    }
    project.remove()
    if let failure { throw failure }
}
