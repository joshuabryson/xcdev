public struct XcdError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String
    public var next: String?
    public var details: [String]

    public init(_ code: ErrorCode, _ message: String, next: String? = nil, details: [String] = []) {
        self.code = code
        self.message = message
        self.next = next
        self.details = details
    }

    public var description: String { "\(code.rawValue): \(message)" }
}
