import Foundation

public enum LibghosttyConfigReloadResult: Equatable, Sendable {
    case unchanged
    case applied
    case appliedWithWarnings([String])
    case rejected([String])
    case failed(String)
}

public struct LibghosttyConfigReloadNotice:
    Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case success
        case error
    }

    public let id: UUID
    public let kind: Kind
    public let message: String

    public init(
        id: UUID = UUID(),
        kind: Kind,
        message: String
    ) {
        self.id = id
        self.kind = kind
        self.message = message
    }
}
