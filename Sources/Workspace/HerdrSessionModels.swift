import Foundation

public enum HerdrSessionState:
    String, Codable, Equatable, Hashable, Sendable {
    case running
    case stopped
}

public struct HerdrSessionSummary: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var isDefault: Bool
    public var state: HerdrSessionState

    public init(
        name: String,
        isDefault: Bool,
        state: HerdrSessionState
    ) {
        self.name = name
        self.isDefault = isDefault
        self.state = state
    }
}

public struct WorkspaceHerdrSessionSelection:
    Equatable, Hashable, Identifiable, Sendable {
    public var hostID: UUID
    public var name: String

    public init(hostID: UUID, name: String) {
        self.hostID = hostID
        self.name = name
    }

    public var id: String {
        "\(hostID.uuidString):\(name)"
    }
}
