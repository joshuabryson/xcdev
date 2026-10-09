import Foundation
import Synchronization
import XcdevKit

/// An `ArrivalLooking` for unit tests: answers each look from a list and records what was asked.
public final class FakeArrival: ArrivalLooking {
    public struct Look: Sendable, Equatable {
        public let target: String
        public let timeout: Duration
        public let device: String
        /// How many commands had run when the look was made, which tells a look before a delivery from one after it.
        public let commandsBefore: Int
    }

    private let state: Mutex<(answers: [Result<ArrivalSight, XcdError>], looks: [Look])>
    private let runner: FakeProcessRunner?
    private let clock: Shared<Date>?

    /// `answers` are given in order, and the last one repeats. With `runner`, each look records how many commands
    /// had run by then. With `clock`, a look that does not find its element moves that clock on by its timeout, since
    /// the real look waits that long before it gives up.
    public init(_ answers: [Result<ArrivalSight, XcdError>] = [.success(.found(seconds: 0.6))], runner: FakeProcessRunner? = nil,
                clock: Shared<Date>? = nil) {
        state = Mutex((answers, []))
        self.runner = runner
        self.clock = clock
    }

    public var looks: [Look] { state.withLock { $0.looks } }

    public func look(for target: String, timeout: Duration, device: String, in ctx: inout WorktreeContext) async throws -> ArrivalSight {
        let commands = runner?.calls.count ?? 0
        let answer = state.withLock { state in
            state.looks.append(Look(target: target, timeout: timeout, device: device, commandsBefore: commands))
            return state.answers.count > 1 ? state.answers.removeFirst() : state.answers[0]
        }
        if case .success(.missing) = answer { clock?.change { $0 += DurationText.seconds(timeout) } }
        return try answer.get()
    }
}
