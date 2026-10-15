import Foundation

/// How a resolved route reaches the app.
public enum RouteDelivery: Sendable, Equatable {
    /// A link opened on the device.
    case url(String)
    /// Arguments and environment variables the app is started with (the preset's are not included).
    case launch(arguments: [String], environment: [String: String])
    /// The project's script, the variables it gets, and the `XCD_PARAM_*` names left unset.
    case script(command: String, environment: [String: String], unset: [String])

    public var kind: RouteSpec.Kind {
        switch self {
        case .url: return .url
        case .launch: return .launch
        case .script: return .run
        }
    }
}

/// A route with its parameters filled in: exactly what will be sent.
public struct ResolvedRoute: Sendable, Equatable {
    /// Nil for a URL given directly.
    public let name: String?
    public let delivery: RouteDelivery
    public let preset: String?
    /// The arrival check's target, with its placeholders filled in.
    public let expect: String?
    /// How long a script may take.
    public let timeout: Duration
    /// A parameter the route's `expect` could name, when the route has parameters and its `expect` names none of
    /// them: an element that is the same whichever value the link carries may be on screen before the link.
    public var unnamedParameter: String?

    /// Whether this is an http or https link, which the system routes like one a person tapped.
    public var isWebLink: Bool {
        guard case .url(let url) = delivery, let scheme = LinkScheme.of(url) else { return false }
        return LinkScheme.isWeb(scheme)
    }

    /// A link that no route describes. It is sent as given, never re-encoded.
    public static func direct(_ url: String) -> ResolvedRoute {
        ResolvedRoute(name: nil, delivery: .url(url), preset: nil, expect: nil, timeout: RouteSpec.defaultTimeout)
    }
}

/// Turns a route and the caller's parameters into what will be sent. Every mistake is
/// a `usage` error that shows the route's parameters, and none of it touches a device.
public struct RouteResolver: Sendable {
    public let config: XcdevConfig

    public init(config: XcdevConfig) { self.config = config }

    public func resolve(_ request: OpenRequest) throws -> ResolvedRoute {
        switch request {
        case .list:
            throw XcdError(.usage, "nothing to open", next: OpenRequest.forms)
        case .url(let url):
            return .direct(url)
        case .route(let name, let values):
            return try resolve(name, values)
        }
    }

    func resolve(_ name: String, _ given: [String: String]) throws -> ResolvedRoute {
        let spec = try route(named: name)
        let values = try self.values(given, for: spec, route: name)
        let fill: (String) -> String = { values[$0] ?? config.linkVars[$0] ?? "" }
        return ResolvedRoute(name: name, delivery: try delivery(spec, values, route: name), preset: spec.preset,
                             expect: try spec.expect.map { try expect($0, fill, route: name) }, timeout: spec.timeoutDuration,
                             unnamedParameter: try unnamedParameter(of: spec))
    }

    /// The route's first parameter by name, when the route has parameters and its `expect` names none of them.
    func unnamedParameter(of spec: RouteSpec) throws -> String? {
        guard let expect = spec.expect, let first = spec.allParams.keys.sorted().first else { return nil }
        let named = Set(try template(expect).names)
        return spec.allParams.keys.contains(where: named.contains) ? nil : first
    }

    /// The route's `expect` with its values filled in. A value can leave it with nothing to look for: `label~{title}`
    /// with an empty title is `label~`, which is no target.
    func expect(_ text: String, _ fill: (String) -> String, route: String) throws -> String {
        let target = try template(text).filled(fill)
        switch TargetParser.parse(target) {
        case .success(.id), .success(.label), .success(.labelContains):
            return target
        case .success(.ref), .success(.point), .failure:
            throw XcdError(.usage, "route '\(route)' expects '\(text)', which names nothing with these values: '\(target)'",
                           next: "give the parameters it uses a value that is not empty")
        }
    }

    func route(named name: String) throws -> RouteSpec {
        if let spec = config.routes[name] { return spec }
        guard !config.routes.isEmpty else {
            throw XcdError(.usage, "this project defines no routes, so there is no route '\(name)'",
                           next: "add routes under `deeplinks:` in .xcdev.yml (`xcd guide deeplinks`)")
        }
        let close = Suggest.closest(to: name, in: config.routes.keys.sorted())
        throw XcdError(.usage, "no route named '\(name)'",
                       next: (close.isEmpty ? "" : "did you mean \(close.map { "`\($0)`" }.joined(separator: ", "))? ")
                           + "`xcd open` lists every route")
    }

    /// Each parameter's text: the caller's value, else its default. An optional parameter left out has none.
    func values(_ given: [String: String], for spec: RouteSpec, route: String) throws -> [String: String] {
        let params = spec.allParams
        if let unknown = given.keys.sorted().first(where: { params[$0] == nil }) {
            let close = Suggest.closest(to: unknown, in: params.keys.sorted(), limit: 1).first.map { " (did you mean '\($0)'?)" } ?? ""
            throw usage("route '\(route)' has no parameter '\(unknown)'" + close, spec, route)
        }
        let missing = params.keys.sorted().filter { params[$0]?.isRequired == true && given[$0] == nil }
        guard missing.isEmpty else { throw usage("route '\(route)' needs \(missing.joined(separator: " and "))", spec, route) }
        var values: [String: String] = [:]
        for (name, param) in params.sorted(by: { $0.key < $1.key }) {
            guard let value = given[name] ?? param.defaultValue else { continue }
            if let allowed = param.values, !allowed.contains(value) {
                throw usage("\(name)=\(value) is not one of: \(allowed.joined(separator: ", "))", spec, route)
            }
            values[name] = value
        }
        return values
    }

    func delivery(_ spec: RouteSpec, _ values: [String: String], route: String) throws -> RouteDelivery {
        let plain: (String) -> String = { values[$0] ?? config.linkVars[$0] ?? "" }
        if let url = spec.url {
            let template = try urlTemplate(url)
            return .url(template.filled { name in
                guard spec.allParams[name] != nil else { return config.linkVars[name] }
                return values[name].map { spec.allParams[name]?.isRaw == true ? $0 : LinkEncoding.encode($0) }
            })
        }
        if let launch = spec.launch {
            return .launch(arguments: try (launch.args ?? []).map { try template($0).filled(plain) },
                           environment: try (launch.env ?? [:]).mapValues { try template($0).filled(plain) })
        }
        var environment = [ContextInfo.routeKey: route]
        for (name, value) in values { environment[Self.variable(name)] = value }
        let unset = spec.allParams.keys.filter { values[$0] == nil }.map(Self.variable).sorted()
        return .script(command: spec.run ?? "", environment: environment, unset: unset)
    }

    /// The environment variable a script reads a parameter from.
    static func variable(_ param: String) -> String { ContextInfo.paramPrefix + param.uppercased() }

    func usage(_ message: String, _ spec: RouteSpec, _ route: String) -> XcdError {
        XcdError(.usage, message, next: "run it as `\(RouteListing.usage(route, spec))`",
                 details: RouteListing.paramRows(spec).map { $0.trimmingCharacters(in: .whitespaces) })
    }

    // The config loader has already read every template, so these only fail on a config that was never validated.
    private func template(_ text: String) throws -> LinkTemplate {
        do { return try LinkTemplate(text) } catch { throw Self.unreadable(text, error) }
    }

    private func urlTemplate(_ text: String) throws -> URLTemplate {
        do { return try URLTemplate(text) } catch { throw Self.unreadable(text, error) }
    }

    private static func unreadable(_ text: String, _ error: any Error) -> XcdError {
        XcdError(.configInvalid, "'\(text)' \((error as? LinkTemplate.Problem)?.message ?? "\(error)")",
                 next: "fix it under `deeplinks:` in .xcdev.yml")
    }
}
