import Foundation

public struct TmuxSessionVisibility: Equatable, Sendable {
    public var hiddenPatterns: [String]
    public var hideKwtManagedSessions: Bool

    public init(
        hiddenPatterns: [String] = [],
        hideKwtManagedSessions: Bool = true
    ) {
        self.hiddenPatterns = hiddenPatterns
        self.hideKwtManagedSessions = hideKwtManagedSessions
    }

    public func isHidden(_ sessionName: String) -> Bool {
        hiddenPatterns.contains { pattern in
            Self.matches(sessionName, pattern: pattern)
        }
    }

    private static func matches(
        _ value: String,
        pattern: String
    ) -> Bool {
        let value = Array(value)
        var previous = Array(repeating: false, count: value.count + 1)
        previous[0] = true

        for token in pattern {
            var current = Array(repeating: false, count: value.count + 1)
            if token == "*" {
                current[0] = previous[0]
                for index in value.indices {
                    current[index + 1] = previous[index + 1]
                        || current[index]
                }
            } else {
                for index in value.indices {
                    current[index + 1] = previous[index]
                        && (token == "?" || token == value[index])
                }
            }
            previous = current
        }

        return previous[value.count]
    }
}
