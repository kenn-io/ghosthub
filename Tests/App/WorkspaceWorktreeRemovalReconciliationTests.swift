import GhosthubTransport
import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

extension WorkspaceWorktreeRemovalTests {
    @MainActor
    @Test("refresh failure after removal is a reconciliation warning")
    func refreshFailureDoesNotUndoRemoval() async throws {
        let fixture = try removalFixture(branch: "main")
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let loads = LockedValue(0)
        let removals = LockedValue(0)
        let beforeRemoval = fixture.beforeRemoval
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                let attempt = loads.load()
                if attempt == 1 {
                    return beforeRemoval
                }
                throw KwtInventoryError.commandFailed(
                    host: "this Mac",
                    status: 23
                )
            },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        try await model.removeWorktree(request)

        #expect(removals.load() == 1)
        #expect(loads.load() == 2)
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        #expect(
            model.workspaceInventoryWarningsByHost[
                environment.host.id
            ] != nil
        )
        await model.shutdown()
    }

    @MainActor
    @Test("successful removal cancels pending window restoration")
    func removalCancelsPendingRestoration() async throws {
        let fixture = try removalFixture(
            path: "/tmp/ghosthub-restoration-boundary",
            name: "feature/restoration-boundary",
            branch: "feature/restoration-boundary",
            sessionName: "kwt-ghosthub-restoration-boundary"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let loads = LockedValue(0)
        let beforeRemoval = fixture.beforeRemoval
        let afterRemoval = inventory(environment)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in
                loads.withLock { $0 += 1 }
                return loads.load() == 1 ? beforeRemoval : afterRemoval
            },
            kwtWorktreeRemover: { _, _, _, _, _ in },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        model.beginRestoration(WorkspaceWindowState(
            windowID: UUID(),
            navigation: .init(
                hostKey: "unavailable-host",
                projectKey: nil,
                worktreeGeneration: nil
            ),
            tmux: nil
        ))

        let request = try await model.prepareWorktreeRemoval(removable.id)
        try await model.removeWorktree(request)

        #expect(!model.isWorkspaceRestorationPending)
        #expect(model.snapshot.worktree(id: removable.id) == nil)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "changed target metadata invalidates the removal confirmation",
        arguments: [
            (
                branch: "feature/replacement",
                session: "kwt-ghosthub-feature"
            ),
            (
                branch: "feature/remove",
                session: "kwt-ghosthub-replacement"
            ),
        ]
    )
    func changedTargetAbortsRemoval(
        replacementBranch: String,
        replacementSession: String
    ) async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var replacement = removable
        replacement.branch = replacementBranch
        replacement.name = replacementBranch
        replacement.tmuxSessionName = replacementSession
        let events = LockedValue<[String]>([])
        let replacementInventory = inventory(
            environment,
            including: replacement
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in replacementInventory },
            kwtWorktreeRemover: { _, _, _, _, _ in
                events.withLock { $0.append("remove") }
            },
            tmuxSessionKiller: { _, _, _ in
                events.withLock { $0.append("kill") }
            },
            tmuxSessionIdentityReader: { _, _ in
                TmuxSessionIdentity(
                    serverPID: "31415",
                    sessionID: "$8",
                    createdAt: "1721552400"
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        do {
            try await model.removeWorktree(request)
            Issue.record("Changed worktree metadata should require confirmation")
        } catch {
            #expect(
                error as? KwtWorktreeError
                    == KwtWorktreeError.removalTargetChanged
            )
        }

        #expect(events.load().isEmpty)
        #expect(
            model.snapshot.worktree(id: removable.id)?.branch
                == replacementBranch
        )
        #expect(
            model.snapshot.worktree(id: removable.id)?.tmuxSessionName
                == replacementSession
        )
        await model.shutdown()
    }

    @MainActor
    @Test("a moved worktree outranks a replacement reusing its runtime ID")
    func movedWorktreeRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var moved = removable
        moved.path = "/tmp/project-a-moved"
        moved.scopedKey = moved.path
        let replacementGeneration = "fedcba9876543210fedcba9876543210"
        var inventoryAfterMove = inventory(environment, including: moved)
        inventoryAfterMove.projects[0].worktrees.append(KwtWorktreeRecord(
            path: removable.path,
            branch: "feature/replacement",
            commitHash: "",
            isMain: false,
            createdAt: nil,
            generation: replacementGeneration,
            repository: environment.project.scopedKey,
            sessionName: "kwt-project-a-replacement",
            tmuxSocketName: nil
        ))
        let movedInventory = inventoryAfterMove
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in movedInventory },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in identity }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.id != request.worktree.id)
        #expect(updatedRequest.worktree.path == moved.path)
        #expect(
            updatedRequest.worktree.generation
                == stableWorktreeGeneration
        )
        #expect(kills.load() == 0)
        #expect(removals.load() == 0)
        #expect(
            model.snapshot.worktree(id: removable.id)?.generation
                == replacementGeneration
        )
        #expect(model.snapshot.worktree(id: updatedRequest.worktree.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a moved worktree uses the newly reported protected endpoint")
    func movedWorktreeUsesNewProtectedEndpoint() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected",
            tmuxAttachMode: .protected
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var moved = removable
        moved.path = "/tmp/project-a-moved"
        moved.scopedKey = moved.path
        var inventoryAfterMove = inventory(environment, including: moved)
        let recordIndex = try #require(
            inventoryAfterMove.projects[0].worktrees.firstIndex {
                $0.path == moved.path
            }
        )
        inventoryAfterMove.projects[0]
            .worktrees[recordIndex].tmuxSocketName = nil
        let movedInventory = inventoryAfterMove
        let probes = LockedValue<[String?]>([])
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in movedInventory },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                probes.withLock { $0.append(selection.socketName) }
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.path == moved.path)
        #expect(updatedRequest.worktree.tmuxSocketName == nil)
        #expect(probes.load() == ["protected", nil])
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "a replacement claiming the confirmed tmux endpoint requires confirmation",
        arguments: ["protected", nil] as [String?]
    )
    func replacementClaimingTmuxEndpointRequiresConfirmation(
        replacementSocket: String?
    ) async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected",
            tmuxAttachMode: .protected
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var replacement = WorktreeSummary.fixture(
            hostID: removable.hostID,
            projectID: removable.projectID,
            scopedKey: "/tmp/project-a-replacement",
            name: removable.name,
            path: "/tmp/project-a-replacement",
            branch: removable.branch,
            generation: "fedcba9876543210fedcba9876543210"
        )
        replacement.tmuxSessionName = removable.tmuxSessionName
        replacement.tmuxSocketName = replacementSocket
        replacement.tmuxAttachMode = .protected
        let replacementInventory = inventory(
            environment,
            including: replacement,
            generation: replacement.generation
        )
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in replacementInventory },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in identity }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Replacement should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.path == replacement.path)
        #expect(updatedRequest.worktree.generation == replacement.generation)
        #expect(updatedRequest.worktree.tmuxSocketName == replacementSocket)
        #expect(kills.load() == 0)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test(
        "a different project claiming removal identity fails closed",
        arguments: [true, false]
    )
    func differentProjectClaimingRemovalIdentityFailsClosed(
        claimsGeneration: Bool
    ) async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected",
            tmuxAttachMode: .protected
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var conflictingInventory = inventory(environment)
        conflictingInventory.projects.append(KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "/tmp/project-b",
                name: "project-b",
                path: "/tmp/project-b",
                lastTouched: nil
            ),
            worktrees: [
                KwtWorktreeRecord(
                    path: "/tmp/project-b-feature",
                    branch: "feature/other",
                    commitHash: "",
                    isMain: false,
                    createdAt: nil,
                    generation: claimsGeneration
                        ? stableWorktreeGeneration
                        : "fedcba9876543210fedcba9876543210",
                    repository: "/tmp/project-b",
                    sessionName: claimsGeneration
                        ? "kwt-project-b-feature"
                        : removable.tmuxSessionName ?? "",
                    tmuxSocketName: claimsGeneration
                        ? nil
                        : removable.tmuxSocketName,
                    tmuxAttachMode: .protected
                ),
            ],
            warning: nil
        ))
        let preflightInventory = conflictingInventory
        let removals = LockedValue(0)
        let kills = LockedValue(0)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflightInventory },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in identity }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.worktreeUnavailable) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(kills.load() == 0)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a snapshot-moved worktree requires a refreshed confirmation")
    func snapshotMovedWorktreeRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        var moved = WorktreeSummary.fixture(
            hostID: removable.hostID,
            projectID: removable.projectID,
            scopedKey: "/tmp/project-a-moved",
            name: removable.name,
            path: "/tmp/project-a-moved",
            branch: removable.branch,
            generation: stableWorktreeGeneration
        )
        moved.tmuxSessionName = removable.tmuxSessionName
        model.snapshot.worktrees.removeAll { $0.id == removable.id }
        model.snapshot.worktrees.append(moved)

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.id == moved.id)
        #expect(updatedRequest.worktree.path == moved.path)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a snapshot-moved project requires a refreshed confirmation")
    func snapshotMovedProjectRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let movedPath = "/tmp/project-a-moved"
        model.snapshot.projects[0].rootPath = movedPath

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.project.rootPath == movedPath)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a snapshot-removed worktree remains unavailable")
    func snapshotRemovedWorktreeRemainsUnavailable() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        model.snapshot.worktrees.removeAll { $0.id == removable.id }

        await #expect(throws: KwtWorktreeError.worktreeUnavailable) {
            try await model.resolveWorktreeRemoval(request)
        }
        await model.shutdown()
    }

    @MainActor
    @Test("a snapshot-recreated endpoint owner requires confirmation")
    func snapshotRecreatedEndpointOwnerRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected",
            tmuxAttachMode: .protected
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let index = try #require(
            model.snapshot.worktrees.firstIndex { $0.id == removable.id }
        )
        model.snapshot.worktrees[index].generation =
            "fedcba9876543210fedcba9876543210"

        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Replacement should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.worktree.id == removable.id)
        #expect(
            updatedRequest.worktree.generation
                == "fedcba9876543210fedcba9876543210"
        )
        #expect(updatedRequest.worktree.tmuxSocketName == "protected")
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("a recreated worktree requires a refreshed confirmation")
    func recreatedWorktreeRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let removals = LockedValue(0)
        let recreatedInventory = inventory(
            environment,
            including: removable,
            generation: "fedcba9876543210fedcba9876543210"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in recreatedInventory },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(
            updatedRequest.worktree.generation
                == "fedcba9876543210fedcba9876543210"
        )
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("an omitted preflight socket requires renewed confirmation")
    func omittedPreflightSocketRequiresConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature",
            socketName: "protected",
            tmuxAttachMode: .protected
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        var preflight = fixture.beforeRemoval
        let recordIndex = try #require(
            preflight.projects[0].worktrees.firstIndex {
                $0.path == removable.path
            }
        )
        preflight.projects[0].worktrees[recordIndex].tmuxSocketName = nil
        let omissionPreflight = preflight
        let removals = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in omissionPreflight },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)

        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Unresolved endpoint should require confirmation")
            await model.shutdown()
            return
        }
        #expect(updatedRequest.worktree.tmuxAttachMode == .protected)
        #expect(updatedRequest.worktree.tmuxSocketName == nil)
        #expect(removals.load() == 0)
        await model.shutdown()
    }

    @MainActor
    @Test("an unchanged recovery request remains an error")
    func unchangedRecoveryRequestRemainsAnError() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let beforeRemoval = fixture.beforeRemoval
        let expected = KwtWorktreeError.removalTargetChanged
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _, _ in throw expected },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        await model.shutdown()
    }

    @MainActor
    @Test("an unrelated removal failure is not recoverable")
    func unrelatedFailureRemainsAnError() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let expected = KwtWorktreeError.removalFailed(
            host: "this Mac",
            status: 42
        )
        let beforeRemoval = fixture.beforeRemoval
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in beforeRemoval },
            kwtWorktreeRemover: { _, _, _, _, _ in throw expected },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        await model.shutdown()
    }

    @MainActor
    @Test("a missing project invalidates cached removal state")
    func missingProjectInvalidatesCachedState() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in KwtHostInventory(projects: []) },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: KwtWorktreeError.worktreeUnavailable) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(model.snapshot.worktree(id: removable.id) == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a warning-bearing preflight cannot trigger reconfirmation")
    func warningPreflightRemainsAnError() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let hostSummary = try #require(snapshot.host(id: environment.host.id))
        let warning = "Project inventory is temporarily unavailable."
        var warningInventory = inventory(environment)
        warningInventory.projects[0].warning = warning
        let preflight = warningInventory
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let expected = KwtWorktreeError.removalPreflightUnavailable(
            host: hostSummary.name,
            message: warning
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("an unrelated project warning prevents absent-target removal")
    func unrelatedProjectWarningPreventsAbsentTargetRemoval() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let hostSummary = try #require(snapshot.host(id: environment.host.id))
        let warning = "Another project inventory is temporarily unavailable."
        var warningInventory = inventory(environment)
        warningInventory.projects.append(KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "example.com/acme/unavailable",
                name: "unavailable",
                path: "/tmp/project-b",
                lastTouched: nil
            ),
            worktrees: [],
            warning: warning
        ))
        let preflight = warningInventory
        let kills = LockedValue(0)
        let removals = LockedValue(0)
        let identity = TmuxSessionIdentity(
            serverPID: "31415",
            sessionID: "$8",
            createdAt: "1721552400"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            kwtWorktreeRemover: { _, _, _, _, _ in
                removals.withLock { $0 += 1 }
            },
            tmuxSessionKiller: { _, _, _ in
                kills.withLock { $0 += 1 }
            },
            tmuxSessionIdentityReader: { _, _ in identity }
        )
        let expected = KwtWorktreeError.removalPreflightUnavailable(
            host: hostSummary.name,
            message: warning
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(kills.load() == 0)
        #expect(removals.load() == 0)
        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a failed project-list preflight cannot trigger reconfirmation")
    func projectListWarningPreflightRemainsAnError() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let hostSummary = try #require(snapshot.host(id: environment.host.id))
        let warning = "Project listing is temporarily unavailable."
        let preflight = KwtHostInventory(
            projects: [],
            projectsWarning: warning
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )
        let expected = KwtWorktreeError.removalPreflightUnavailable(
            host: hostSummary.name,
            message: warning
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        await #expect(throws: expected) {
            try await model.resolveWorktreeRemoval(request)
        }

        #expect(model.snapshot.worktree(id: removable.id) != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a changed project path refreshes removal confirmation")
    func changedProjectPathRefreshesConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot
        let movedPath = "/tmp/project-a-moved"
        var movedInventory = fixture.beforeRemoval
        movedInventory.projects[0].project.path = movedPath
        let preflight = movedInventory
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.project.rootPath == movedPath)
        #expect(model.snapshot.project(id: environment.project.id)?.rootPath == movedPath)
        await model.shutdown()
    }

    @MainActor
    @Test("project path reuse refreshes confirmation for the moved repository")
    func projectPathReuseRefreshesMovedRepositoryConfirmation() async throws {
        let fixture = try removalFixture(
            path: "/tmp/project-a-feature",
            sessionName: "kwt-project-a-feature"
        )
        let environment = fixture.environment
        let removable = fixture.removable
        let snapshot = fixture.snapshot

        let movedPath = "/tmp/project-a-moved"
        var movedProject = fixture.beforeRemoval.projects[0]
        movedProject.project.path = movedPath
        let replacementRepository = "example.com/acme/replacement"
        let replacementProject = KwtProjectInventory(
            project: KwtProjectRecord(
                repository: replacementRepository,
                name: "replacement",
                path: environment.project.rootPath,
                lastTouched: nil
            ),
            worktrees: [
                KwtWorktreeRecord(
                    path: environment.project.rootPath,
                    branch: "main",
                    commitHash: "",
                    isMain: true,
                    createdAt: nil,
                    generation: nil,
                    repository: replacementRepository,
                    sessionName: "kwt-replacement-main",
                    tmuxSocketName: nil
                ),
            ],
            warning: nil
        )
        let preflight = KwtHostInventory(projects: [
            replacementProject,
            movedProject,
        ])
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: snapshot,
            kwtInventoryLoader: { _ in preflight },
            tmuxSessionIdentityReader: { selection, host in
                throw TmuxSessionKillError.sessionNotRunning(
                    host: host.displayName,
                    session: selection.name
                )
            }
        )

        let request = try await model.prepareWorktreeRemoval(removable.id)
        let result = try await model.resolveWorktreeRemoval(request)
        guard case let .confirmationRequired(updatedRequest) = result else {
            Issue.record("Removal should require a new confirmation")
            await model.shutdown()
            return
        }

        #expect(updatedRequest.project.id == environment.project.id)
        #expect(updatedRequest.project.scopedKey == environment.project.scopedKey)
        #expect(updatedRequest.project.rootPath == movedPath)
        #expect(updatedRequest.worktree.generation == stableWorktreeGeneration)
        let hostProjects = model.snapshot.projects.filter {
            $0.hostID == environment.host.id
        }
        #expect(Set(hostProjects.map(\.id)).count == hostProjects.count)
        #expect(
            hostProjects.first { $0.scopedKey == replacementRepository }?.id
                != environment.project.id
        )
        await model.shutdown()
    }

    @MainActor
    @Test("removal completion keeps the owning project selected")
    func removalKeepsOwningProjectSelected() throws {
        let environment = try setupStandardEnvironment()
        let removed = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            name: "feature/remove",
            path: "/tmp/project-a-feature"
        )
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removed)
        var current = WorkspaceSelection(
            selectedHostID: environment.host.id
        )
        current.select(
            WorkspaceNavigationTarget.worktree(removed.id),
            in: snapshot
        )
        snapshot.worktrees.removeAll { $0.id == removed.id }

        let resolved = WorkspaceSceneModel.selectionAfterWorktreeRemoval(
            current,
            in: snapshot,
            visibility: WorktreeVisibility.default
        )

        #expect(resolved.selectedProjectID == environment.project.id)
        #expect(resolved.selectedWorktreeID == nil)
    }

    @MainActor
    @Test("removal completion preserves newer navigation")
    func removalPreservesCurrentSelection() throws {
        let environment = try setupStandardEnvironment()
        let removed = WorktreeSummary.fixture(
            hostID: environment.host.id,
            projectID: environment.project.id,
            name: "feature/remove",
            path: "/tmp/ghosthub-feature"
        )
        var snapshot = environment.snapshot
        snapshot.worktrees.append(removed)
        var current = WorkspaceSelection(
            selectedHostID: environment.host.id
        )
        current.select(
            WorkspaceNavigationTarget.worktree(environment.worktree.id),
            in: snapshot
        )
        snapshot.worktrees.removeAll { $0.id == removed.id }

        let resolved = WorkspaceSceneModel.selectionAfterWorktreeRemoval(
            current,
            in: snapshot,
            visibility: WorktreeVisibility.default
        )

        #expect(resolved.selectedWorktreeID == environment.worktree.id)
    }
}
