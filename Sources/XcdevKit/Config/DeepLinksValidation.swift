import Foundation

/// The cross-field checks on `deeplinks:`. Each issue names the key it is about.
enum DeepLinksValidation {
    static let routeName = #"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$"#
    static let valueName = #"^[A-Za-z][A-Za-z0-9_]*$"#

    static func issues(_ config: XcdevConfig) -> [ConfigIssue] {
        let vars = config.linkVars
        var issues: [ConfigIssue] = []
        for name in vars.keys.sorted() where !matches(name, valueName) {
            issues.append(ConfigIssue(path: "deeplinks.vars.\(name)",
                                      message: "'\(name)' is not a valid var name (a letter, then letters, digits, and '_')"))
        }
        for (name, spec) in config.routes.sorted(by: { $0.key < $1.key }) {
            let route = RouteCheck(path: "deeplinks.routes.\(name)", spec: spec, vars: vars, presets: config.presets ?? [:])
            if !matches(name, routeName) {
                issues.append(route.issue("", "'\(name)' is not a valid route name (segments of letters, digits, '.', '_' and '-', joined by '/')"))
            }
            issues += route.issues()
        }
        return issues
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// One route's checks.
struct RouteCheck {
    let path: String
    let spec: RouteSpec
    let vars: [String: String]
    let presets: [String: LaunchPreset]

    var optional: Set<String> { Set(spec.allParams.filter { $0.value.isOptional }.keys) }

    func issue(_ key: String, _ message: String) -> ConfigIssue {
        ConfigIssue(path: key.isEmpty ? path : path + "." + key, message: message)
    }

    func issues() -> [ConfigIssue] {
        var issues = kindIssues() + settingIssues()
        var used = Set<String>()
        for (key, text) in templates() {
            issues += templateIssues(key: key, text: text, used: &used)
        }
        issues += paramIssues(used: used)
        return issues
    }

    /// Exactly one of url, launch, and run, and none of them empty.
    func kindIssues() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        let kinds = spec.kinds.map(\.rawValue)
        if kinds.isEmpty { issues.append(issue("", "needs one of url, launch, or run")) }
        if kinds.count > 1 {
            issues.append(issue("", "has \(kinds.joined(separator: " and ")); a route has exactly one of url, launch, or run"))
        }
        if spec.description.trimmingCharacters(in: .whitespaces).isEmpty { issues.append(issue("description", "must not be empty")) }
        for (key, value) in [("url", spec.url), ("run", spec.run)] where value?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            issues.append(issue(key, "must not be empty"))
        }
        if let launch = spec.launch, (launch.args ?? []).isEmpty, (launch.env ?? [:]).isEmpty {
            issues.append(issue("launch", "needs args or env"))
        }
        return issues
    }

    /// preset, timeout, and expect.
    func settingIssues() -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        if let preset = spec.preset {
            if spec.run != nil {
                issues.append(issue("preset", "is not allowed on a run route: its script starts the app itself"))
            } else if presets[preset] == nil {
                issues.append(issue("preset", "'\(preset)' is not a key under presets"))
            }
        }
        if let timeout = spec.timeout {
            if spec.run == nil {
                issues.append(issue("timeout", "only applies to a run route"))
            } else if DurationText.parse(timeout) == nil {
                issues.append(issue("timeout", "'\(timeout)' is not a duration like \"30s\", \"5m\", or \"1h\""))
            }
        }
        return issues
    }

    /// Every text that placeholders are read in, with its key. `run` is not one: a script gets its values as
    /// environment variables.
    func templates() -> [(key: String, text: String)] {
        var found: [(key: String, text: String)] = []
        if let url = spec.url { found.append(("url", url)) }
        for (index, argument) in (spec.launch?.args ?? []).enumerated() { found.append(("launch.args[\(index)]", argument)) }
        for (name, value) in (spec.launch?.env ?? [:]).sorted(by: { $0.key < $1.key }) { found.append(("launch.env.\(name)", value)) }
        if let expect = spec.expect { found.append(("expect", expect)) }
        return found
    }

    func templateIssues(key: String, text: String, used: inout Set<String>) -> [ConfigIssue] {
        let names: [String]
        do {
            names = key == "url" ? try URLTemplate(text).names : try LinkTemplate(text).names
        } catch {
            return [issue(key, (error as? LinkTemplate.Problem)?.message ?? "\(error)")]
        }
        used.formUnion(names)
        var issues = Set(names).subtracting(spec.allParams.keys).subtracting(vars.keys).sorted().map {
            issue(key, "{\($0)} is neither a parameter of this route nor a var")
        }
        switch key {
        case "url": issues += urlIssues(text)
        case "expect": issues += expectIssues(text, names: names)
        default: break
        }
        return issues
    }

    func urlIssues(_ text: String) -> [ConfigIssue] {
        guard let url = try? URLTemplate(text) else { return [] }
        var issues: [ConfigIssue] = []
        // A parameter's place is held by a character no scheme has, so only a var can supply the scheme.
        let withVars = (try? LinkTemplate(text).filled { vars[$0] ?? "{" }) ?? text
        if LinkScheme.of(withVars) == nil {
            issues.append(issue("url", "has no scheme (like myapp: or https:) once its vars are filled in; a parameter cannot supply it"))
        }
        for name in url.misplaced(optional: optional) {
            issues.append(issue("params.\(name)", "is optional, so {\(name)} may only be the whole value of a query item in the url, like \(name)={\(name)}"))
        }
        return issues
    }

    func expectIssues(_ text: String, names: [String]) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        let sample = (try? LinkTemplate(text).filled { _ in "x" }) ?? text
        switch TargetParser.parse(sample) {
        case .success(.id), .success(.label), .success(.labelContains): break
        default: issues.append(issue("expect", "'\(text)' is not an `id:<identifier>`, `label:<text>`, or `label~<part>` target"))
        }
        for name in names where optional.contains(name) {
            issues.append(issue("expect", "uses {\(name)}, which is optional; expect may only use parameters that always have a value"))
        }
        return issues
    }

    func paramIssues(used: Set<String>) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        let names = spec.allParams.keys.sorted()
        for name in names {
            guard let param = spec.allParams[name] else { continue }
            let key = "params.\(name)"
            if !DeepLinksValidation.matches(name, DeepLinksValidation.valueName) {
                issues.append(issue(key, "'\(name)' is not a valid parameter name (a letter, then letters, digits, and '_')"))
            }
            issues += nameClashes(name, among: names).map { issue(key, $0) }
            issues += valueIssues(name, param)
            if spec.run == nil, !used.contains(name) { issues.append(issue(key, "is not used by any placeholder")) }
            if spec.launch != nil, param.isOptional {
                issues.append(issue(key, "is optional, which a launch route does not allow: give it a default, or leave it required"))
            }
            if param.raw != nil, spec.url == nil { issues.append(issue(key + ".raw", "only applies to a parameter of a url route")) }
        }
        return issues
    }

    /// A script sees parameters upper-cased, and `{name}` must mean one thing.
    func nameClashes(_ name: String, among names: [String]) -> [String] {
        var clashes = names.filter { $0 > name && $0.lowercased() == name.lowercased() }
            .map { "differs from the parameter '\($0)' only in case" }
        if vars[name] != nil {
            clashes.append("has the same name as a var; rename one of them")
        } else if let other = vars.keys.sorted().first(where: { $0.lowercased() == name.lowercased() }) {
            clashes.append("differs from the var '\(other)' only in case")
        }
        return clashes
    }

    func valueIssues(_ name: String, _ param: RouteParam) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        let key = "params.\(name)"
        if param.defaultValue != nil, param.isOptional {
            issues.append(issue(key, "has both default and optional; an optional parameter has no default"))
        }
        if let values = param.values {
            if values.isEmpty { issues.append(issue(key + ".values", "must not be empty")) }
            if let value = param.defaultValue, !values.isEmpty, !values.contains(value) {
                issues.append(issue(key + ".default", "'\(value)' is not one of values: \(values.joined(separator: ", "))"))
            }
        }
        return issues
    }
}
