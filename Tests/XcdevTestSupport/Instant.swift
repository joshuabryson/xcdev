/// Stand-ins for time in unit tests.
public enum Instant {
    /// A `sleep` that returns at once, so code that polls runs through its looks without waiting.
    public static let sleep: @Sendable (Duration) async throws -> Void = { _ in /* nothing to wait for in a test */ }
}
