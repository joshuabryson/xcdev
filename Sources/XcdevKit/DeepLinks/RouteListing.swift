import Foundation

/// How routes and their parameters are written out, for the list and for `usage` errors.
enum RouteListing {
    /// "  id   required  The link's UUID", one row per parameter, names padded to one width.
    static func paramRows(_ spec: RouteSpec) -> [String] {
        let width = spec.allParams.keys.map(\.count).max() ?? 0
        return spec.allParams.sorted { $0.key < $1.key }.map { name, param in
            var cells = [name.padding(toLength: width, withPad: " ", startingAt: 0), need(param)]
            if let values = param.values { cells.append(values.joined(separator: "|")) }
            if param.isRaw { cells.append("raw") }
            if let description = param.description { cells.append(description) }
            return "  " + cells.joined(separator: "  ")
        }
    }

    static func need(_ param: RouteParam) -> String {
        if let value = param.defaultValue { return "default=\(value)" }
        return param.isOptional ? "optional" : "required"
    }

    /// "xcd open item id=<id> [tab=<notes|preview>]": required parameters, then the ones that may be left out.
    static func usage(_ route: String, _ spec: RouteSpec) -> String {
        let params = spec.allParams.sorted { $0.key < $1.key }
        let words = params.filter { $0.value.isRequired }.map { pair($0.key, $0.value) }
            + params.filter { !$0.value.isRequired }.map { "[" + pair($0.key, $0.value) + "]" }
        return (["xcd open", route] + words).joined(separator: " ")
    }

    private static func pair(_ name: String, _ param: RouteParam) -> String {
        "\(name)=<\(param.values?.joined(separator: "|") ?? name)>"
    }
}
