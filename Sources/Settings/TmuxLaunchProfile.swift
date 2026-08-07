import Foundation

public struct TmuxLaunchProfile:
    Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String

    public init(
        id: UUID = UUID(),
        name: String,
        command: String
    ) {
        self.id = id
        self.name = name
        self.command = command
    }
}
