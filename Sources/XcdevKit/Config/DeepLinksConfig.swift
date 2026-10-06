/// `deeplinks:`: the links the app can open, by name.
public struct DeepLinksConfig: Codable, Sendable, Equatable {
    /// Text any route can use as `{name}`.
    public var vars: [String: String]?
    public var routes: [String: RouteSpec]?

    public init(vars: [String: String]? = nil, routes: [String: RouteSpec]? = nil) {
        self.vars = vars
        self.routes = routes
    }
}

/// One route under `deeplinks.routes`. Exactly one of `url`, `launch`, and `run` is set: the config loader checks it.
public struct RouteSpec: Codable, Sendable, Equatable {
    public var description: String
    public var url: String?
    public var launch: Launch?
    public var run: String?
    public var params: [String: RouteParam]?
    public var preset: String?
    public var expect: String?
    public var timeout: String?

    public struct Launch: Codable, Sendable, Equatable {
        public var args: [String]?
        public var env: [String: String]?

        public init(args: [String]? = nil, env: [String: String]? = nil) {
            self.args = args
            self.env = env
        }
    }

    /// How a route is delivered, named as its key in the config.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case url, launch, run
    }

    public init(description: String, url: String? = nil, launch: Launch? = nil, run: String? = nil,
                params: [String: RouteParam]? = nil, preset: String? = nil, expect: String? = nil, timeout: String? = nil) {
        self.description = description
        self.url = url
        self.launch = launch
        self.run = run
        self.params = params
        self.preset = preset
        self.expect = expect
        self.timeout = timeout
    }

    /// The delivery keys the route has. A valid route has exactly one.
    public var kinds: [Kind] {
        var found: [Kind] = []
        if url != nil { found.append(.url) }
        if launch != nil { found.append(.launch) }
        if run != nil { found.append(.run) }
        return found
    }

    public static let defaultTimeout: Duration = .seconds(300)

    public var allParams: [String: RouteParam] { params ?? [:] }
    public var timeoutDuration: Duration { timeout.flatMap(DurationText.parse) ?? Self.defaultTimeout }
}

/// One parameter under a route's `params`.
public struct RouteParam: Codable, Sendable, Equatable {
    public var description: String?
    public var defaultValue: String?
    public var optional: Bool?
    public var values: [String]?
    public var raw: Bool?

    enum CodingKeys: String, CodingKey {
        case description, optional, values, raw
        case defaultValue = "default"
    }

    public init(description: String? = nil, defaultValue: String? = nil, optional: Bool? = nil, values: [String]? = nil,
                raw: Bool? = nil) {
        self.description = description
        self.defaultValue = defaultValue
        self.optional = optional
        self.values = values
        self.raw = raw
    }

    public var isOptional: Bool { optional ?? false }
    public var isRaw: Bool { raw ?? false }
    /// The caller must give a value: there is no default, and the parameter is not optional.
    public var isRequired: Bool { defaultValue == nil && !isOptional }
}
