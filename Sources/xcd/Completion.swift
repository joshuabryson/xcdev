import ArgumentParser
import XcdevKit

extension CompletionKind {
    /// Values read from the project when the user presses Tab.
    static func project(_ values: @escaping @Sendable (Completions) async -> [String]) -> CompletionKind {
        .custom { _, _, _ in await values(.live()) }
    }

    static let devices = project { await $0.devices() }
    /// Route names for the first argument of `xcd open`.
    static let routes = CompletionKind.custom { words, index, _ in await Completions.live().routes(words, at: index) }
}
