import Foundation

struct TmuxVersion: Comparable, Equatable, Sendable {
    static let minimumSupported = Self(major: 3, minor: 2)
    static let minimumFind = Self(major: 3, minor: 4)
    static let searchCount = Self(major: 3, minor: 5)
    static let copyModeOptionParsing = Self(major: 3, minor: 6)

    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(output: String) {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "tmux" else { return nil }
        let components = fields[1].split(separator: ".", maxSplits: 1)
        guard components.count == 2,
              let major = Int(components[0]),
              let minor = Int(components[1].prefix(while: \.isNumber))
        else { return nil }
        self.init(major: major, minor: minor)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}
