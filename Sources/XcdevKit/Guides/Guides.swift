/// A Markdown guide written for agents, compiled into the binary so it always matches this version of xcd.
public struct Guide: Codable, Sendable, Equatable {
    public let topic: String
    /// The guide's title (its first `# ` heading).
    public let summary: String
    public let markdown: String
}

public enum Guides {
    /// Every guide, sorted by topic. The sources are docs/agents/guides/<topic>.md.
    public static var all: [Guide] {
        GuideText.topics.sorted { $0.key < $1.key }.map { topic, markdown in
            let title = markdown.split(separator: "\n").first.map(String.init) ?? topic
            return Guide(topic: topic, summary: title.hasPrefix("# ") ? String(title.dropFirst(2)) : title, markdown: markdown)
        }
    }

    public static func guide(_ topic: String) throws -> Guide {
        if let guide = all.first(where: { $0.topic == topic }) { return guide }
        let topics = all.map(\.topic)
        let close = Suggest.closest(to: topic, in: topics, limit: 1)
        throw XcdError(.usage, "there is no guide named '\(topic)'",
                       next: close.first.map { "did you mean `xcd guide \($0)`?" } ?? "use one of: \(topics.joined(separator: ", "))")
    }
}

/// `xcd guide [<topic>]`: one guide's Markdown, or the list of topics.
public struct GuideReport: Reportable {
    public let guides: [Guide]
    public let single: Bool

    public init(topic: String?) throws {
        if let topic {
            guides = [try Guides.guide(topic)]
            single = true
        } else {
            guides = Guides.all
            single = false
        }
    }

    public var text: String {
        if single, let guide = guides.first { return guide.markdown }
        let width = (guides.map(\.topic.count).max() ?? 0) + 2
        let rows = guides.map { $0.topic.padding(toLength: width, withPad: " ", startingAt: 0) + $0.summary }
        return (rows + ["read one: xcd guide <topic>"]).joined(separator: "\n")
    }
}
