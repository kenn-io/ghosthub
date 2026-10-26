import Foundation
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubUI

@MainActor
struct WorktreeFlagPresentationTests {
    @Test("flag presentation restores each worktree type", arguments: [true, false])
    func iconRestoration(_ primary: Bool) {
        let flagged = WorktreeFlagPresentation(isFlagged: true, isPrimary: primary)
        #expect(flagged.systemImageName == "flag.fill")
        #expect(flagged.titleColor == .orange)
        let normal = WorktreeFlagPresentation(isFlagged: false, isPrimary: primary)
        #expect(normal.systemImageName == (primary
                ? WorkspaceSidebarRowIcon.primaryWorktree.systemImageName
                : WorkspaceSidebarRowIcon.worktree.systemImageName))
        #expect(normal.titleColor == .primary)
    }

    @Test("every worktree menu has flag and changes actions without a session")
    func sessionlessMenu() throws {
        let key = try #require(FlagTestWorkspace().key)
        let groups = WorktreeMenuAction.groups(
            flagKey: key, isFlagged: false, isExpanded: false,
            canKill: false, canRemove: false
        )
        #expect(groups == [[.setFlagged(key, true), .setChangesExpanded(true)]])
        #expect(groups[0].map(\.title) == ["Flag Worktree", "Show Changes"])
        #expect(groups[0].allSatisfy { $0.isEnabled })
    }

    @Test("flagged removable rows retain grouped destructive actions")
    func liveMenu() throws {
        let key = try #require(FlagTestWorkspace().key)
        let groups = WorktreeMenuAction.groups(
            flagKey: key, isFlagged: true, isExpanded: true,
            canKill: true, canRemove: true
        )
        #expect(groups == [
            [.setFlagged(key, false), .setChangesExpanded(false)],
            [.killSession, .removeWorktree],
        ])
        #expect(groups[0].map(\.title) == ["Unflag Worktree", "Hide Changes"])
        #expect(groups[1].allSatisfy { $0.isDestructive })
    }

    @Test("missing identity disables only flagging")
    func missingIdentity() {
        let groups = WorktreeMenuAction.groups(
            flagKey: nil, isFlagged: false, isExpanded: false,
            canKill: true, canRemove: false
        )
        #expect(!groups[0][0].isEnabled)
        #expect(groups[0][1].isEnabled)
        #expect(groups[1] == [.killSession])
    }

    @Test("late flag actions cannot target a replacement or removed worktree")
    func lateAction() throws {
        let fixture = try FlagStoreFixture()
        let store = fixture.store()
        var workspace = FlagTestWorkspace()
        let key = try #require(workspace.key)
        let id = workspace.worktreeID
        workspace.snapshot.worktrees[0].generation = String(repeating: "b", count: 32)
        #expect(throws: WorktreeFlagUpdateError.identityChanged) {
            try store.setFlagged(true, for: key, worktreeID: id, in: workspace.snapshot)
        }
        #expect(store.flaggedKeys.isEmpty)
        workspace.snapshot.worktrees = []
        #expect(throws: WorktreeFlagUpdateError.identityChanged) {
            try store.setFlagged(true, for: key, worktreeID: id, in: workspace.snapshot)
        }
    }

    @Test("captured flag actions preserve subsequent changes to other keys")
    func staleMenuState() throws {
        let fixture = try FlagStoreFixture()
        let store = fixture.store()
        let first = FlagTestWorkspace()
        var second = FlagTestWorkspace()
        second.snapshot.worktrees[0].generation = String(repeating: "b", count: 32)
        let firstKey = try #require(first.key)
        let secondKey = try #require(second.key)
        try store.setFlagged(true, for: secondKey)
        try store.setFlagged(true, for: firstKey, worktreeID: first.worktreeID, in: first.snapshot)
        #expect(store.flaggedKeys == [firstKey, secondKey])
    }

    @Test("cached inventory keys do not depend on flag membership")
    func inventoryCache() throws {
        let workspace = FlagTestWorkspace()
        let fixture = try FlagStoreFixture()
        let store = fixture.store()
        let cache = WorkspaceSidebarSectionCache()
        let first = cache.sections(in: workspace.snapshot, snapshotRevision: 0)
        let key = try #require(first[0].projects[0].worktreeRows[0].worktreeFlagKey)
        try store.setFlagged(true, for: key)
        RenderWorkCounters.beginRecording()
        let repeated = cache.sections(in: workspace.snapshot, snapshotRevision: 0)
        let counts = RenderWorkCounters.endRecording()
        #expect(repeated == first)
        #expect(counts.sidebarSectionComputations == 0)
        #expect(store.isFlagged(key))
        #expect(first[0].projects[0].worktreeRows[0].icon == .worktree)
    }

    @Test("flag accessibility preserves selection and session status")
    func accessibility() {
        let row = WorkspaceSidebarRow(
            target: .worktree(UUID()), icon: .primaryWorktree,
            title: "main", sessionIsRunning: true
        )
        let descriptor = WorkspaceAccessibilityModel.descriptor(
            for: row, isSelected: true, isWorktreeFlagged: true
        )
        #expect(descriptor.value == "Flagged, Primary checkout, Session running, Selected")
        #expect(WorkspaceAccessibilityModel.descriptor(for: row, isSelected: false)
            .value == "Session running")
    }

    @Test("flag failures use a distinct alert identity")
    func failureAlert() {
        let alert = WorkspaceAlert.worktreeFlagFailure(worktree: "main", message: "Try again.")
        #expect(alert.id == "worktree-flag:failure:main:Try again.")
        #expect(WorktreeFlagUpdateError.identityChanged.localizedDescription
            == "This worktree changed. Reopen its actions menu and try again.")
    }
}
