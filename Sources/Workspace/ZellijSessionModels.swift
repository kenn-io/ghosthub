import Foundation

public enum ZellijSessionName {
    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isAttachable(_ name: String) -> Bool {
        !name.isEmpty
            && (!name.hasPrefix("-") || name == "-")
            && name != "help" && name != "options"
    }

    public static func isValid(_ value: String) -> Bool {
        let name = normalized(value)
        guard isAttachable(name), name != ".", name != "..", !name.contains("/")
        else { return false }
        return !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        })
    }
}

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
