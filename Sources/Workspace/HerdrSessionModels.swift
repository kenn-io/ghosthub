import Foundation

public enum HerdrBackend: String, Codable, Hashable, Sendable {
    case tui
    case core
}

public enum HerdrSessionState:
    String, Codable, Equatable, Hashable, Sendable {
    case running
    case stopped
}

public struct HerdrSessionSummary: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var backend: HerdrBackend
    public var title: String
    public var isDefault: Bool
    public var state: HerdrSessionState

    public init(
        name: String,
        isDefault: Bool,
        state: HerdrSessionState,
        backend: HerdrBackend = .tui,
        title: String? = nil
    ) {
        self.name = name
        self.backend = backend
        self.title = title ?? name
        self.isDefault = isDefault
        self.state = state
    }

    public func matches(_ selection: WorkspaceHerdrSessionSelection) -> Bool {
        name == selection.name && backend == selection.backend
    }
}

public struct WorkspaceHerdrSessionSelection:
    Equatable, Hashable, Identifiable, Sendable {
    public var hostID: UUID
    public var name: String
    public var backend: HerdrBackend

    public init(hostID: UUID, name: String, backend: HerdrBackend = .tui) {
        self.hostID = hostID
        self.name = name
        self.backend = backend
    }

    public var id: String {
        backend == .tui
            ? "\(hostID.uuidString):\(name)"
            : "core:\(hostID.uuidString):\(name)"
    }
}
