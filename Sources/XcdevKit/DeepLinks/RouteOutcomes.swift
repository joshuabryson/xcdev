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
    case appeared, inconclusive, skipped
}
