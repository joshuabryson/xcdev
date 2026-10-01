public enum Suggest {
    /// Up to `limit` candidates close to `input` (edit distance, or containing it), best first.
    public static func closest(to input: String, in candidates: [String], limit: Int = 3) -> [String] {
        let needle = input.lowercased()
        let threshold = max(2, input.count / 2)
        let scored = candidates.map { ($0, distance(needle, $0.lowercased())) }
        let filtered = scored.filter { $0.1 <= threshold || $0.0.lowercased().contains(needle) }
        let sorted = filtered.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let prefixed = sorted.prefix(limit)
        return Array(prefixed).map(\.0)
    }

    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[b.count]
    }
}
