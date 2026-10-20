import Foundation
import GhosthubTmux
@testable import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

extension WorkspaceTmuxDiscoveryTests {
    @MainActor
    @Test("renaming the open session keeps its terminal attached")
    func renameKeepsOpenSessionAttached() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["anchor": "$1", "desk": "$2"])
        let renames = LockedValue<[(String, String, TmuxSessionIdentity)]>([])
        let store = SceneTmuxSurfaceStoreStub()
        let defaults = try #require(UserDefaults(
            suiteName: "ghosthub-rename-\(UUID().uuidString)"
        ))
        defaults.set(
            [
                WorkspaceSidebarModel.tmuxSessionOrderID(
                    hostID: hostID,
                    name: "desk"
                ),
                WorkspaceSidebarModel.tmuxSessionOrderID(
                    hostID: hostID,
                    name: "anchor"
                ),
            ].joined(separator: "\n"),
            forKey: WorkspaceSidebarOrderStorage.tmuxSessionKey
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
            tmuxSessionRenamer: { selection, newName, identity, _ in
                renames.withLock {
                    $0.append((selection.name, newName, identity))
                }
                names.withLock { renameFixtureSession(
                    &$0,
                    from: selection.name,
                    to: newName
                ) }
            },
            sidebarOrderDefaults: defaults
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 2
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)
        let handle = try #require(model.retainedBorrowedTmuxHandle(for: desk))
        let surfaceRequests = store.requestCount

        try await model.renameTmuxSession(desk, to: "  work  ")

        let recorded = renames.load()
        #expect(recorded.count == 1)
        #expect(recorded.first?.0 == "desk")
        #expect(recorded.first?.1 == "work")
        #expect(recorded.first?.2 == renameFixtureIdentity("$2"))
        #expect(
            Set(model.snapshot.hosts[0].tmuxSessions.map(\.name))
                == ["anchor", "work"]
        )
        let work = WorkspaceTmuxSessionSelection(hostID: hostID, name: "work")
        let renamed = try #require(model.retainedBorrowedTmuxHandle(for: work))
        #expect(model.activeBorrowedTmuxSelection == work)
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(renamed.id == handle.id)
        #expect(renamed.surfaceID == handle.surfaceID)
        #expect(store.removedKeys.isEmpty)
        #expect(store.requestCount == surfaceRequests)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(
            WorkspaceSidebarOrderStorage.tmuxSessionRawValue(in: defaults)
                .split(separator: "\n").map(String.init) == [
                    WorkspaceSidebarModel.tmuxSessionOrderID(
                        hostID: hostID,
                        name: "work"
                    ),
                    WorkspaceSidebarModel.tmuxSessionOrderID(
                        hostID: hostID,
                        name: "anchor"
                    ),
                ]
        )

        // The terminal's close callback still reaches the renamed session.
        store.surface.closeObservers[handle.id]?(false, 1)
        await waitUntilMainActor {
            !model.activeBorrowedTmuxSessionIsConnected
        }
        await model.shutdown()
    }

    @MainActor
    @Test("renaming onto an ended session's name drops its closed terminal")
    func renameOntoEndedSessionName() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["build": "$3", "desk": "$2"])
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
            tmuxSessionRenamer: { selection, newName, _, _ in
                names.withLock { renameFixtureSession(
                    &$0,
                    from: selection.name,
                    to: newName
                ) }
            }
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 2
        }
        let build = WorkspaceTmuxSessionSelection(hostID: hostID, name: "build")
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        model.openBorrowedTmuxSession(build)
        await connectActiveRenameSession(model, store: store)
        let ended = try #require(model.retainedBorrowedTmuxHandle(for: build))
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)
        let handle = try #require(model.retainedBorrowedTmuxHandle(for: desk))

        store.surface.closeObservers[ended.id]?(false, 1)
        names.withLock { $0["build"] = nil }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.map(\.name) == ["desk"]
        }

        try await model.renameTmuxSession(desk, to: "build")

        let renamed = try #require(model.retainedBorrowedTmuxHandle(for: build))
        #expect(renamed.id == handle.id)
        #expect(model.activeBorrowedTmuxSelection == build)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test("a rename moves the session in every window that shows it")
    func renameReachesOtherWindows() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
        let coordinator = TmuxSessionRenameCoordinator()
        var models: [WorkspaceSceneModel] = []
        var stores: [SceneTmuxSurfaceStoreStub] = []
        for _ in 0 ..< 2 {
            let store = SceneTmuxSurfaceStoreStub()
            let model = try makeModel(
                database: environment.database,
                localHostID: hostID,
                snapshot: environment.snapshot,
                nativeTmuxSurfaceStore: store,
                nativeTmuxPathProvider: {
                    successfulTmuxResolution("/usr/bin/tmux")
                },
                tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
                tmuxSessionRenamer: { selection, newName, _, _ in
                    names.withLock { renameFixtureSession(
                        &$0,
                        from: selection.name,
                        to: newName
                    ) }
                },
                tmuxSessionRenameCoordinator: coordinator
            )
            models.append(model)
            stores.append(store)
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        var handles: [BorrowedTmuxSessionHandle] = []
        for (model, store) in zip(models, stores) {
            model.startTmuxSessionDiscovery()
            await waitUntilMainActor {
                model.snapshot.hosts[0].tmuxSessions.count == 1
            }
            model.openBorrowedTmuxSession(desk)
            await connectActiveRenameSession(model, store: store)
            try handles.append(#require(model.retainedBorrowedTmuxHandle(
                for: desk
            )))
        }

        try await models[0].renameTmuxSession(desk, to: "work")

        let work = WorkspaceTmuxSessionSelection(hostID: hostID, name: "work")
        let other = models[1]
        #expect(other.retainedBorrowedTmuxHandle(for: work)?.id == handles[1].id)
        #expect(other.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(other.activeBorrowedTmuxSelection == work)
        #expect(other.snapshot.hosts[0].tmuxSessions.map(\.name) == ["work"])
        #expect(stores[1].removedKeys.isEmpty)
        for model in models {
            await model.shutdown()
        }
    }

    @MainActor
    @Test("a rename waits until the open session finishes connecting")
    func renameWaitsForConnection() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
        let renames = LockedValue(0)
        let tmuxResolved = DispatchGroup()
        tmuxResolved.enter()
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                tmuxResolved.wait()
                return successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
            tmuxSessionRenamer: { selection, newName, _, _ in
                renames.withLock { $0 += 1 }
                names.withLock { renameFixtureSession(
                    &$0,
                    from: selection.name,
                    to: newName
                ) }
            }
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 1
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        model.openBorrowedTmuxSession(desk)
        model.prepareActiveBorrowedTmuxSurface()
        let handle = try #require(model.retainedBorrowedTmuxHandle(for: desk))

        await #expect {
            try await model.renameTmuxSession(desk, to: "work")
        } throws: { error in
            error as? TmuxSessionRenameError
                == .sessionConnecting(session: "desk")
        }
        #expect(renames.load() == 0)
        #expect(model.retainedBorrowedTmuxHandle(for: desk)?.id == handle.id)

        tmuxResolved.leave()
        await connectActiveRenameSession(model, store: store)
        try await model.renameTmuxSession(desk, to: "work")

        let work = WorkspaceTmuxSessionSelection(hostID: hostID, name: "work")
        #expect(renames.load() == 1)
        #expect(model.retainedBorrowedTmuxHandle(for: work)?.id == handle.id)
        #expect(model.activeBorrowedTmuxSelection == work)
        await model.shutdown()
    }

    @MainActor
    @Test("a window still connecting keeps its terminal when another renames")
    func renameLeavesConnectingWindowAttached() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
        let coordinator = TmuxSessionRenameCoordinator()
        let tmuxResolved = DispatchGroup()
        tmuxResolved.enter()
        var models: [WorkspaceSceneModel] = []
        var stores: [SceneTmuxSurfaceStoreStub] = []
        for index in 0 ..< 2 {
            let store = SceneTmuxSurfaceStoreStub()
            let model = try makeModel(
                database: environment.database,
                localHostID: hostID,
                snapshot: environment.snapshot,
                nativeTmuxSurfaceStore: store,
                nativeTmuxPathProvider: {
                    if index == 1 {
                        tmuxResolved.wait()
                    }
                    return successfulTmuxResolution("/usr/bin/tmux")
                },
                tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
                tmuxSessionRenamer: { selection, newName, _, _ in
                    names.withLock { renameFixtureSession(
                        &$0,
                        from: selection.name,
                        to: newName
                    ) }
                },
                tmuxSessionRenameCoordinator: coordinator
            )
            models.append(model)
            stores.append(store)
            model.startTmuxSessionDiscovery()
            await waitUntilMainActor {
                model.snapshot.hosts[0].tmuxSessions.count == 1
            }
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        models[0].openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(models[0], store: stores[0])
        let connecting = models[1]
        connecting.openBorrowedTmuxSession(desk)
        connecting.prepareActiveBorrowedTmuxSurface()
        let handle = try #require(connecting.retainedBorrowedTmuxHandle(
            for: desk
        ))

        try await models[0].renameTmuxSession(desk, to: "work")

        #expect(connecting.retainedBorrowedTmuxHandle(for: desk)?.id == handle.id)
        #expect(connecting.activeBorrowedTmuxSelection == desk)
        #expect(stores[1].removedKeys.isEmpty)
        tmuxResolved.leave()
        for model in models {
            await model.shutdown()
        }
    }

    @MainActor
    @Test("an Always Live refresh during a rename keeps the terminal open")
    func alwaysLiveRefreshDuringRename() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
        let renamed = KillGate()
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: renameIdentitySplitter(names),
            tmuxSessionDiscovery: { _ in
                .success(renameFixture(names, live: true))
            },
            tmuxSessionRenamer: { selection, newName, _, _ in
                names.withLock { renameFixtureSession(
                    &$0,
                    from: selection.name,
                    to: newName
                ) }
                await renamed.suspend()
            },
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let notes = WorkspaceTmuxSessionSelection(hostID: hostID, name: "notes")
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: desk) != nil
        }
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)
        let handle = try #require(model.retainedBorrowedTmuxHandle(for: desk))
        let surfaceRequests = store.requestCount

        let rename = Task { try await model.renameTmuxSession(desk, to: "notes") }
        await renamed.waitUntilStarted()
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.map(\.name) == ["notes"]
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(model.retainedBorrowedTmuxHandle(for: notes)?.id == handle.id)
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(model.activeBorrowedTmuxSelection == notes)
        #expect(store.removedKeys.isEmpty)

        await renamed.release()
        try await rename.value

        #expect(model.retainedBorrowedTmuxHandle(for: notes)?.id == handle.id)
        #expect(model.activeBorrowedTmuxSelection == notes)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.retainedBorrowedTmuxPresentationCount == 1)
        #expect(store.removedKeys.isEmpty)
        #expect(store.requestCount == surfaceRequests)
        await model.shutdown()
    }

    @MainActor
    @Test("a terminal opened under the new name stays open when the rename lands")
    func renameKeepsTerminalOpenedUnderNewName() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
        let renamed = KillGate()
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
            tmuxSessionRenamer: { selection, newName, _, _ in
                names.withLock { renameFixtureSession(
                    &$0,
                    from: selection.name,
                    to: newName
                ) }
                await renamed.suspend()
            }
        )
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let notes = WorkspaceTmuxSessionSelection(hostID: hostID, name: "notes")
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 1
        }
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)

        let rename = Task { try await model.renameTmuxSession(desk, to: "notes") }
        await renamed.waitUntilStarted()
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.map(\.name) == ["notes"]
        }
        model.openBorrowedTmuxSession(notes)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSelection == notes
                && model.activeBorrowedTmuxSessionIsConnected
        }
        let opened = try #require(model.retainedBorrowedTmuxHandle(for: notes))

        await renamed.release()
        try await rename.value

        #expect(model.retainedBorrowedTmuxHandle(for: notes)?.id == opened.id)
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(model.activeBorrowedTmuxSelection == notes)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test("rename refuses taken names and kwt-owned sessions without running tmux")
    func renameRefusesTakenAndOwnedNames() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        var snapshot = environment.snapshot
        snapshot.worktrees[0].tmuxSessionName = "notes"
        snapshot.worktrees[0].tmuxSocketName = nil
        let renames = LockedValue(0)
        let discovered = [
            ("anchor", nil as String?),
            ("desk", nil),
            ("managed", "kwt"),
        ].enumerated().map { index, session in
            DiscoveredTmuxSession(
                name: session.0,
                socketName: session.1,
                windowCount: 1,
                serverPID: "101",
                sessionID: "$\(index)",
                createdAt: "1000",
                managed: false
            )
        }
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: snapshot,
            tmuxSessionDiscovery: { _ in .success(discovered) },
            tmuxSessionRenamer: { _, _, _, _ in
                renames.withLock { $0 += 1 }
            }
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 3
        }

        await #expect {
            try await model.renameTmuxSession(
                WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk"),
                to: "anchor"
            )
        } throws: { error in
            error as? TmuxSessionRenameError == .nameInUse(
                host: "localhost",
                name: "anchor"
            )
        }
        await #expect(throws: TmuxSessionRenameError.self) {
            try await model.renameTmuxSession(
                WorkspaceTmuxSessionSelection(
                    hostID: hostID,
                    name: "managed",
                    socketName: "kwt"
                ),
                to: "mine"
            )
        }
        await #expect(throws: TmuxSessionRenameError.self) {
            try await model.renameTmuxSession(
                WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk"),
                to: "has.period"
            )
        }
        for kwtName in ["kwt-wt-ghosthub-main-abc123", "notes"] {
            await #expect {
                try await model.renameTmuxSession(
                    WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk"),
                    to: kwtName
                )
            } throws: { error in
                error as? TmuxSessionRenameError == .nameOwnedByKwt(
                    host: "localhost",
                    name: kwtName
                )
            }
        }
        #expect(renames.load() == 0)
        #expect(
            model.snapshot.hosts[0].tmuxSessions.map(\.name).sorted()
                == ["anchor", "desk", "managed"]
        )
        await model.shutdown()
    }
}

/// `live` reports the sizes Always Live needs to connect every session.
private func renameFixture(
    _ sessions: LockedValue<[String: String]>,
    live: Bool = false
) -> [DiscoveredTmuxSession] {
    sessions.load().sorted { $0.key < $1.key }.map { name, sessionID in
        DiscoveredTmuxSession(
            name: name,
            windowCount: 1,
            serverPID: "101",
            sessionID: sessionID,
            createdAt: "1000",
            activeWindowSize: live ? TmuxGridSize(columns: 120, rows: 36) : nil,
            previewClientSize: live ? TmuxGridSize(columns: 120, rows: 37) : nil,
            managed: false
        )
    }
}

/// Reports the fixture's only session as the one each client attached to.
private func renameIdentitySplitter(
    _ sessions: LockedValue<[String: String]>
) -> TmuxPaneSplitter {
    TmuxPaneSplitter { _, _, command in
        guard command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"),
              let sessionID = sessions.load().values.first
        else { return (0, "") }
        return (
            0,
            "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                + "\t101\t789\t321\t/dev/ttys001\t\(sessionID)\t1000\t%9\n"
        )
    }
}

/// Tmux keeps the session id across a rename.
private func renameFixtureSession(
    _ sessions: inout [String: String],
    from oldName: String,
    to newName: String
) {
    sessions[newName] = sessions.removeValue(forKey: oldName)
}

private func renameFixtureIdentity(_ sessionID: String) -> TmuxSessionIdentity {
    TmuxSessionIdentity(serverPID: "101", sessionID: sessionID, createdAt: "1000")
}

@MainActor
private func connectActiveRenameSession(
    _ model: WorkspaceSceneModel,
    store: SceneTmuxSurfaceStoreStub
) async {
    await waitUntilMainActor {
        model.prepareActiveBorrowedTmuxSurface()
        return store.requestCount > 0
            && model.activeBorrowedTmuxSessionIsConnected
    }
}
