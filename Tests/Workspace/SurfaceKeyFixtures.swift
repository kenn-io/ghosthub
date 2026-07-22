import Foundation
@testable import GhosthubWorkspace

extension SurfaceKey {
    static func fixture(
        worktreeID: UUID? = UUID(),
        hostID: UUID = UUID(),
        target: TerminalSurfaceTarget = .worktreeShell,
        leafID: UUID? = nil
    ) -> SurfaceKey {
        SurfaceKey(
            worktreeID: worktreeID,
            hostID: hostID,
            target: target,
            leafID: leafID
        )
    }

    /// Console surface with no worktree association.
    static func consoleFixture(
        hostID: UUID = UUID(),
        leafID: UUID? = nil
    ) -> SurfaceKey {
        fixture(
            worktreeID: nil,
            hostID: hostID,
            target: .console,
            leafID: leafID
        )
    }

    /// Surface key for a worktree shell bound to a leaf.
    static func worktreeLeafFixture(
        leafID: UUID = UUID(),
        worktreeID: UUID = UUID(),
        hostID: UUID = UUID()
    ) -> SurfaceKey {
        fixture(
            worktreeID: worktreeID,
            hostID: hostID,
            target: .worktreeShell,
            leafID: leafID
        )
    }

    /// Surface key for a console surface bound to a leaf.
    static func consoleLeafFixture(
        leafID: UUID = UUID(),
        hostID: UUID = UUID()
    ) -> SurfaceKey {
        fixture(
            worktreeID: nil,
            hostID: hostID,
            target: .console,
            leafID: leafID
        )
    }
}
