import Yams

public enum NodeMerge {
    /// Deep-merges mappings; any other overlay value replaces the base value.
    public static func merge(_ base: Node, _ overlay: Node) -> Node {
        guard let baseMapping = base.mapping, let overlayMapping = overlay.mapping else { return overlay }
        var pairs: [(Node, Node)] = baseMapping.map { ($0.key, $0.value) }
        for (key, value) in overlayMapping {
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[index].1 = merge(pairs[index].1, value)
            } else {
                pairs.append((key, value))
            }
        }
        return .mapping(Node.Mapping(pairs))
    }
}
