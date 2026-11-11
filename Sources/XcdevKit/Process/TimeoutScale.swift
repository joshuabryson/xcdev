import Foundation

/// `XCD_TIMEOUT_SCALE`: how many times longer than usual xcd lets the commands it runs take, and waits for a crash
/// report, on a machine slower than the ones its limits were measured on, such as a CI runner. A number of at least 1;
/// unset, or anything else, leaves every limit as it is.
public struct TimeoutScale: Sendable, Equatable {
    public static let variable = "XCD_TIMEOUT_SCALE"
    public let factor: Double

    public init(environment: [String: String]) {
        let value = environment[Self.variable].flatMap(Double.init) ?? 1
        factor = value.isFinite && value >= 1 ? value : 1
    }

    public func scaled(_ duration: Duration) -> Duration { duration * factor }
}
