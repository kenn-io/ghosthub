import Foundation

/// A multiplexer that leaves pane layout to its client app and offers one
/// terminal at a time to attach to. Ghosthub lists those terminals per host
/// and attaches each one to its own surface. The backend owns creation,
/// lifetime, and layout.
public enum BackendTerminalKind: String, Codable, CaseIterable, Hashable, Sendable {
    /// A live terminal of the Herdr desktop app's core, from `herdr-core ls`.
    case herdrCore = "core"
    /// A terminal block on a Rex server, from `kwt rex ls`.
    case rex
}

public struct BackendTerminalSummary: Codable, Equatable, Hashable, Sendable {
    public var kind: BackendTerminalKind
    /// The backend's identity for the terminal on its host: a Herdr Core
    /// address such as `t7`, or a Rex block ID.
    public var address: String
    /// Display text; never identity.
    public var title: String
    /// Secondary display text, such as where the terminal sits in the
    /// backend's own layout.
    public var detail: String?

    public init(
        kind: BackendTerminalKind,
        address: String,
        title: String? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.address = address
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? address
        self.detail = detail
    }

    public func matches(_ selection: WorkspaceBackendTerminalSelection) -> Bool {
        kind == selection.kind && address == selection.address
    }
}

public struct WorkspaceBackendTerminalSelection:
    Equatable, Hashable, Identifiable, Sendable {
    public var hostID: UUID
    public var kind: BackendTerminalKind
    public var address: String

    public init(hostID: UUID, kind: BackendTerminalKind, address: String) {
        self.hostID = hostID
        self.kind = kind
        self.address = address
    }

    public var id: String {
        "\(kind.rawValue):\(hostID.uuidString):\(address)"
    }
}
