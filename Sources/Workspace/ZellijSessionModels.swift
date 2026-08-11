import Foundation

public struct ZellijSessionSummary: Codable, Equatable, Hashable, Sendable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct WorkspaceZellijSessionSelection:
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
