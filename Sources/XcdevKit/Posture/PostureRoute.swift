import Foundation

/// What a route needs to reach one clone.
public struct PostureContext: Sendable {
    public var udid: String
    public var developerDir: String
    public var recipe: DirectRecipe

    public init(udid: String, developerDir: String, recipe: DirectRecipe) {
        self.udid = udid
        self.developerDir = developerDir
        self.recipe = recipe
    }
}

/// Whether a route can be tried.
public enum RouteAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

/// One way of delivering a request to the simulator's pose pipeline. A route says whether it can be tried,
/// then applies the request and keeps whatever it opened alive while `witness` runs.
public protocol PostureRoute: Sendable {
    var id: PostureRouteID { get }
    func availability(_ ctx: PostureContext) async -> RouteAvailability
    /// Sends the request, runs `witness` before releasing its connection, and returns what `witness` returned.
    func apply<Result: Sendable>(_ request: PostureRequest, _ ctx: PostureContext,
                                 holdingUntil witness: () async throws -> Result) async throws -> Result
}
