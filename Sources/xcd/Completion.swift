import ArgumentParser
import XcdevKit

extension CompletionKind {
    /// Values read from the project when the user presses Tab.
    static func project(_ values: @escaping @Sendable (Completions) async -> [String]) -> CompletionKind {
        .custom { _, _, _ in await values(.live()) }
    }

    static let devices = project { await $0.devices() }
}
