public struct Version: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        components = parts.map { $0! }
    }

    init(components: [Int]) { self.components = components }

    public static let zero = Version(components: [0])

    /// Missing trailing components count as zero, so 27 == 27.0.
    public static func < (lhs: Version, rhs: Version) -> Bool {
        for i in 0..<max(lhs.components.count, rhs.components.count) {
            let a = i < lhs.components.count ? lhs.components[i] : 0
            let b = i < rhs.components.count ? rhs.components[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: Version, rhs: Version) -> Bool { !(lhs < rhs) && !(rhs < lhs) }

    public func hasPrefix(_ prefix: Version) -> Bool { components.starts(with: prefix.components) }

    public var description: String { components.map(String.init).joined(separator: ".") }
}
