import Foundation

public enum TerminalSurfaceTarget: String, CaseIterable, Identifiable, Equatable, Sendable {
    case worktreeShell
    case worktreeAssistant
    case console
    case logViewer
    case tmuxSession
    case herdrSession
    case zellijSession

    public var id: String {
        rawValue
    }
}

public struct SurfaceKey: Hashable, Sendable {
    public let worktreeID: UUID?
    public let hostID: UUID
    public let target: TerminalSurfaceTarget
    public let leafID: UUID?

    public init(
        worktreeID: UUID?,
        hostID: UUID,
        target: TerminalSurfaceTarget,
        leafID: UUID? = nil
    ) {
        self.worktreeID = worktreeID
        self.hostID = hostID
        self.target = target
        self.leafID = leafID
    }

    public var scopedKey: String {
        let scope = worktreeID?.uuidString ?? "console"
        let leaf = leafID?.uuidString ?? "root"
        return "surface:\(hostID.uuidString):\(scope):\(target.rawValue):\(leaf)"
    }
}

public typealias WorkspaceTerminalSurfaceTarget = TerminalSurfaceTarget
