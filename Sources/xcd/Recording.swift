import XcdevKit

enum Recording {
    /// Stops this worktree's recordings that ran past ui.record.maxDuration, saying so on stderr.
    /// `sim`, `ui`, `run`, `launch`, and `test` call it; `logs` and `context` don't, so they never cut a recording short.
    static func stopOverdue(_ services: Services, _ ctx: WorktreeContext) async {
        for stop in await services.media.stopOverdue(in: ctx) {
            services.progress(stop.note + " (longer than ui.record.maxDuration)")
        }
    }
}
