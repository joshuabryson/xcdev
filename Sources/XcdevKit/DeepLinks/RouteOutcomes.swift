/// How the app came to be running when a route was delivered.
public enum AppArrival: String, Codable, Sendable, Equatable {
    /// The link went to a copy that was already up.
    case running
    case started
    case restarted
    /// `--cold`: the link itself started the app.
    case startedByLink = "started-by-link"
    /// A script route: xcd left the app alone.
    case untouched
}

/// How a route's arrival check ended.
public enum CheckOutcome: String, Codable, Sendable, Equatable {
    case appeared
    /// The element was on screen before the link was sent, so seeing it afterwards proves nothing.
    case inconclusive
    /// UI driving does not work on this device.
    case skipped
    /// The element did not appear in time: the command fails with `wait_timeout`.
    case missing
    /// The look could not be made: the command fails with the error that stopped it.
    case failed
}
