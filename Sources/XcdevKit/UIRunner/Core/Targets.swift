import Foundation

/// What an action aims at.
public enum TargetSpec: Codable, Sendable, Equatable {
    case id(String)
    case label(String)
    case labelContains(String)
    case ref(String)
    case point(x: Double, y: Double)
}

public struct TargetParseFailure: Error, Sendable, Equatable {
    public let message: String
}

public enum TargetParser {
    public static let forms = "id:<identifier>, label:<text>, label~<part of the label>, ref:e<N> (from `xcd ui tree`), or @x,y"

    public static func parse(_ text: String) -> Result<TargetSpec, TargetParseFailure> {
        let failure = Result<TargetSpec, TargetParseFailure>.failure(TargetParseFailure(message: "'\(text)' is not a target"))
        if text.hasPrefix("@") {
            let parts = text.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return failure }
            return .success(.point(x: x, y: y))
        }
        func rest(_ prefix: String) -> String? {
            guard text.hasPrefix(prefix) else { return nil }
            let value = String(text.dropFirst(prefix.count))
            return value.isEmpty ? nil : value
        }
        if let value = rest("id:") { return .success(.id(value)) }
        if let value = rest("label:") { return .success(.label(value)) }
        if let value = rest("label~") { return .success(.labelContains(value)) }
        if let value = rest("ref:") {
            guard value.hasPrefix("e"), Int(value.dropFirst()) != nil else { return failure }
            return .success(.ref(value))
        }
        return failure
    }
}

public enum MatchOutcome: Sendable, Equatable {
    case one(Int)
    case none
    case ambiguous([Int])
    /// The ref isn't in the table, or its element is gone or no longer unique.
    case staleRef
}

public enum TargetMatcher {
    /// Finds `target` in `nodes`. `.point` targets are not matched here.
    public static func match(_ target: TargetSpec, role: String?, index: Int?, in nodes: [FlatNode],
                             refs: [String: RefSignature]) -> MatchOutcome {
        if case .ref(let name) = target {
            guard let signature = refs[name] else { return .staleRef }
            let found = nodes.indices.filter { nodes[$0].signature == signature }
            return found.count == 1 ? .one(found[0]) : .staleRef
        }
        var found = nodes.indices.filter { i in
            let node = nodes[i]
            guard node.role != "application", role == nil || node.role == role else { return false }
            switch target {
            case .id(let id): return node.identifier == id
            case .label(let label): return node.label == label
            case .labelContains(let part): return node.label.lowercased().contains(part.lowercased())
            case .ref, .point: return false
            }
        }
        found = withoutNestedDuplicates(found, in: nodes)
        if let index { return found.indices.contains(index) ? .one(found[index]) : .none }
        switch found.count {
        case 0: return .none
        case 1: return .one(found[0])
        default: return .ambiguous(found)
        }
    }

    /// When one match is inside another (a button and its own label text), keeps one: the interactive one, else the outer.
    static func withoutNestedDuplicates(_ found: [Int], in nodes: [FlatNode]) -> [Int] {
        var dropped = Set<Int>()
        for inner in found {
            var current = nodes[inner].parent
            while let outer = current {
                if found.contains(outer) {
                    if nodes[inner].isInteractive && !nodes[outer].isInteractive { dropped.insert(outer) } else { dropped.insert(inner) }
                }
                current = nodes[outer].parent
            }
        }
        return found.filter { !dropped.contains($0) }
    }
}
