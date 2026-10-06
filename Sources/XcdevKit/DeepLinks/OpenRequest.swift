/// What `xcd open` was asked for, read from its arguments.
public enum OpenRequest: Sendable, Equatable {
    /// No arguments: list the routes.
    case list
    case route(name: String, values: [String: String])
    /// A link no route describes, sent as given.
    case url(String)

    static let forms = "open a route with `xcd open <route> [name=value …]` or a link with `xcd open <scheme>://…`; `xcd open` alone lists the routes"

    /// The first argument is a URL when it contains `:`, and a route name otherwise. What follows a route name is
    /// its parameters, each `name=value`, split at the first `=`.
    public static func parse(_ arguments: [String]) throws -> OpenRequest {
        guard let first = arguments.first else { return .list }
        let rest = Array(arguments.dropFirst())
        guard first.contains(":") else { return .route(name: first, values: try values(rest)) }
        guard LinkScheme.of(first) != nil else {
            throw XcdError(.usage, "'\(first)' is not a URL: it has no scheme before the ':'", next: forms)
        }
        guard rest.isEmpty else {
            throw XcdError(.usage, "a URL takes no parameters, but got: \(rest.joined(separator: " "))",
                           next: "put the values in the URL itself, or describe the link as a route in .xcdev.yml")
        }
        return .url(first)
    }

    static func values(_ pairs: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        for pair in pairs {
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                throw XcdError(.usage, "'\(pair)' is not name=value",
                               next: "give each parameter as name=value, e.g. `xcd open item id=42`; quote one whose value has spaces")
            }
            let name = String(pair[..<equals])
            guard values[name] == nil else {
                throw XcdError(.usage, "the parameter '\(name)' is given twice", next: "give each parameter once")
            }
            values[name] = String(pair[pair.index(after: equals)...])
        }
        return values
    }
}
