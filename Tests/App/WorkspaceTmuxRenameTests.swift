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
    @Test("a rename onto a name whose session ended keeps a client tmux moved elsewhere")
    func renameOntoEndedNameKeepsSwitchedClient() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["build": "$3", "desk": "$2"])
        let clients = RenameTmuxClients()
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: renameClientSplitter(
                names,
                launches: store.launchCommands,
                clients: clients
            ),
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
        let switched = try #require(model.retainedBorrowedTmuxHandle(for: build))
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)
        let handle = try #require(model.retainedBorrowedTmuxHandle(for: desk))
        await waitUntilMainActor { clients.attached.load().count == 2 }

        // build ends, and tmux moves its still-running client to a session
        // that has no other client.
        names.withLock { $0["build"] = nil }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.map(\.name) == ["desk"]
        }

        try await model.renameTmuxSession(desk, to: "build")
        await waitUntilMainActor {
            model.refreshTmuxSessionDiscovery()
            return clients.refusedDetaches.load() > 0
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(model.retainedBorrowedTmuxHandle(for: build)?.id == switched.id)
        #expect(model.retainedBorrowedTmuxHandle(for: desk)?.id == handle.id)
        #expect(clients.detached.load().isEmpty)

        // Once that session has another client, tmux detaches this one and
        // the renamed session takes the name.
        clients.sessionShared.store(true)
        await waitUntilMainActor {
            model.refreshTmuxSessionDiscovery()
            return model.retainedBorrowedTmuxHandle(for: build)?.id
                == handle.id
        }
        #expect(clients.detached.load() == [clients.tty(for: try #require(
            clients.attached.load().first { $0.value == "$3" }?.key
        ))])
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(model.activeBorrowedTmuxSelection == build)
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
        let clients = RenameTmuxClients()
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
                nativeTmuxPaneSplitter: renameClientSplitter(
                    names,
                    launches: store.launchCommands,
                    clients: index == 1 ? clients : RenameTmuxClients()
                ),
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

        // Once connected, the window applies the rename it had to hold.
        tmuxResolved.leave()
        let work = WorkspaceTmuxSessionSelection(hostID: hostID, name: "work")
        await waitUntilMainActor {
            connecting.prepareActiveBorrowedTmuxSurface()
            return connecting.retainedBorrowedTmuxHandle(for: work)?.id
                == handle.id
        }
        #expect(connecting.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(connecting.activeBorrowedTmuxSelection == work)
        #expect(stores[1].removedKeys.isEmpty)
        // The launch ran after the rename and still reached the session.
        await waitUntilMainActor {
            clients.attached.load().values.contains("$2")
        }
        for model in models {
            await model.shutdown()
        }
    }

    @MainActor
    @Test("a second terminal for the session closes only once tmux confirms the other")
    func renameClosesDuplicateAfterTmuxConfirmsAttachment() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["anchor": "$1", "desk": "$2"])
        let coordinator = TmuxSessionRenameCoordinator()
        let sizingHold = LockedValue<DispatchGroup?>(nil)
        let identityHold = LockedValue<DispatchGroup?>(nil)
        var models: [WorkspaceSceneModel] = []
        var stores: [SceneTmuxSurfaceStoreStub] = []
        let clients = RenameTmuxClients()
        for index in 0 ..< 2 {
            let store = SceneTmuxSurfaceStoreStub()
            let model = try makeModel(
                database: environment.database,
                localHostID: hostID,
                snapshot: environment.snapshot,
                nativeTmuxSurfaceStore: store,
                nativeTmuxPathProvider: {
                    successfulTmuxResolution("/usr/bin/tmux")
                },
                nativeTmuxPaneSplitter: renameClientSplitter(
                    names,
                    launches: store.launchCommands,
                    clients: index == 1 ? clients : RenameTmuxClients(),
                    sizingHold: sizingHold,
                    identityHold: identityHold
                ),
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
                model.snapshot.hosts[0].tmuxSessions.count == 2
            }
        }
        let anchor = WorkspaceTmuxSessionSelection(hostID: hostID, name: "anchor")
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let notes = WorkspaceTmuxSessionSelection(hostID: hostID, name: "notes")
        let window = models[1]
        window.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(window, store: stores[1])
        let moving = try #require(window.retainedBorrowedTmuxHandle(for: desk))

        // Switching away starts a resize that holds the desk terminal in
        // place while the other window renames its session.
        let sizing = DispatchGroup()
        sizing.enter()
        sizingHold.store(sizing)
        window.openBorrowedTmuxSession(anchor)
        await connectActiveRenameSession(window, store: stores[1])
        try await models[0].renameTmuxSession(desk, to: "notes")
        #expect(window.retainedBorrowedTmuxHandle(for: desk)?.id == moving.id)

        let identity = DispatchGroup()
        identity.enter()
        identityHold.store(identity)
        window.openBorrowedTmuxSession(notes)
        await waitUntilMainActor {
            window.prepareActiveBorrowedTmuxSurface()
            return window.activeBorrowedTmuxSelection == notes
                && window.activeBorrowedTmuxSessionIsConnected
        }
        let kept = try #require(window.retainedBorrowedTmuxHandle(for: notes))
        sizingHold.store(nil)
        sizing.leave()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        window.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            window.snapshot.hosts[0].tmuxSessions.map(\.name).sorted()
                == ["anchor", "notes"]
        }

        // tmux has not reported the new terminal's client yet.
        #expect(window.retainedBorrowedTmuxHandle(for: desk)?.id == moving.id)
        #expect(window.retainedBorrowedTmuxHandle(for: notes)?.id == kept.id)

        // The terminal that stays has switched to another session, so tmux
        // refuses to detach the other one and neither may close.
        clients.keeperSwitched.store(true)
        identityHold.store(nil)
        identity.leave()
        await waitUntilMainActor {
            window.refreshTmuxSessionDiscovery()
            return clients.refusedDetaches.load() > 0
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(window.retainedBorrowedTmuxHandle(for: desk)?.id == moving.id)
        #expect(window.retainedBorrowedTmuxHandle(for: notes)?.id == kept.id)

        // The user selects the other terminal while tmux detaches it. The
        // window then shows the kept terminal of the same session.
        let detaching = DispatchGroup()
        detaching.enter()
        clients.detachHold.store(detaching)
        await waitUntilMainActor { clients.unheldDetaches.load() == 0 }
        clients.keeperSwitched.store(false)
        await waitUntilMainActor {
            window.refreshTmuxSessionDiscovery()
            return clients.heldDetaches.load() > 0
        }
        window.openBorrowedTmuxSession(desk)
        await waitUntilMainActor {
            window.activeBorrowedTmuxSelection == desk
        }
        clients.detachHold.store(nil)
        detaching.leave()
        await waitUntilMainActor {
            window.prepareActiveBorrowedTmuxSurface()
            return window.retainedBorrowedTmuxHandle(for: desk) == nil
                && window.activeBorrowedTmuxSelection == notes
                && window.activeBorrowedTmuxSessionIsConnected
        }
        #expect(window.retainedBorrowedTmuxHandle(for: notes)?.id == kept.id)
        for model in models {
            await model.shutdown()
        }
    }

    @MainActor
    @Test("a rename onto a name whose session moved in tmux keeps both terminals")
    func renameOntoNameMovedInTmux() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2", "notes": "$3"])
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
                nativeTmuxPaneSplitter: renameClientSplitter(names, launches: store.launchCommands),
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
                model.snapshot.hosts[0].tmuxSessions.count == 2
            }
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let notes = WorkspaceTmuxSessionSelection(hostID: hostID, name: "notes")
        let other = WorkspaceTmuxSessionSelection(hostID: hostID, name: "other")
        let window = models[1]
        window.openBorrowedTmuxSession(notes)
        await connectActiveRenameSession(window, store: stores[1])
        let moved = try #require(window.retainedBorrowedTmuxHandle(for: notes))
        window.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(window, store: stores[1])
        let renamed = try #require(window.retainedBorrowedTmuxHandle(for: desk))

        // Someone renames notes in tmux. Only the first window has seen it.
        names.withLock { renameFixtureSession(&$0, from: "notes", to: "other") }
        models[0].refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            models[0].snapshot.hosts[0].tmuxSessions.map(\.name).sorted()
                == ["desk", "other"]
        }
        try await models[0].renameTmuxSession(desk, to: "notes")

        #expect(window.retainedBorrowedTmuxHandle(for: notes)?.id == moved.id)
        #expect(window.retainedBorrowedTmuxHandle(for: desk)?.id == renamed.id)
        #expect(stores[1].removedKeys.isEmpty)

        window.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            window.retainedBorrowedTmuxHandle(for: other)?.id == moved.id
        }
        #expect(window.retainedBorrowedTmuxHandle(for: notes)?.id == renamed.id)
        #expect(window.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(window.activeBorrowedTmuxSelection == notes)
        #expect(stores[1].removedKeys.isEmpty)
        for model in models {
            await model.shutdown()
        }
    }

    @MainActor
    @Test("sessions that swap names in tmux keep their terminals")
    func sessionsSwapNamesInTmux() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2", "notes": "$3"])
        let store = SceneTmuxSurfaceStoreStub()
        let window = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: renameClientSplitter(
                names,
                launches: store.launchCommands
            ),
            tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator()
        )
        window.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            window.snapshot.hosts[0].tmuxSessions.count == 2
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let notes = WorkspaceTmuxSessionSelection(hostID: hostID, name: "notes")
        window.openBorrowedTmuxSession(notes)
        await connectActiveRenameSession(window, store: store)
        let wasNotes = try #require(window.retainedBorrowedTmuxHandle(for: notes))
        window.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(window, store: store)
        let wasDesk = try #require(window.retainedBorrowedTmuxHandle(for: desk))

        names.store(["desk": "$3", "notes": "$2"])
        window.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            window.prepareActiveBorrowedTmuxSurface()
            return window.retainedBorrowedTmuxHandle(for: notes)?.id
                == wasDesk.id
        }
        #expect(window.retainedBorrowedTmuxHandle(for: desk)?.id == wasNotes.id)
        #expect(window.activeBorrowedTmuxSelection == notes)
        #expect(window.activeBorrowedTmuxSessionIsConnected)
        #expect(store.removedKeys.isEmpty)
        await window.shutdown()
    }

    @MainActor
    @Test("Always Live keeps a session renamed in tmux when a new one takes its name")
    func alwaysLiveFollowsTmuxRenameWhenOldNameReturns() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
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

        names.withLock {
            renameFixtureSession(&$0, from: "desk", to: "notes")
            $0["desk"] = "$5"
        }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: notes)?.id == handle.id
        }

        #expect(model.activeBorrowedTmuxSelection == notes)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.retainedBorrowedTmuxHandle(for: desk)?.id != handle.id)
        await model.shutdown()
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
    @Test("a session renamed while its SSH client reconnects reattaches under the new name")
    func reconnectFollowsTmuxRename() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let hostID = environment.remoteHost.id
        let names = LockedValue(["release-work": "$2"])
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { host in
                host == .local ? .success([]) : .success(renameFixture(names))
            },
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator(),
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: hostID)?.tmuxSessions.first?.sessionID
                == "$2"
        }
        let releaseWork = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "release-work"
        )
        model.openBorrowedTmuxSession(releaseWork)
        await connectActiveRenameSession(model, store: store)
        let handle = try #require(
            model.retainedBorrowedTmuxHandle(for: releaseWork)
        )

        // The SSH client drops, and the session is renamed in tmux before
        // Ghosthub reconnects.
        names.withLock { renameFixtureSession(
            &$0,
            from: "release-work",
            to: "shipping"
        ) }
        store.surface.closeObservers[handle.id]?(false, 255)

        let shipping = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "shipping"
        )
        await waitUntilMainActor {
            model.activeBorrowedTmuxSelection == shipping
                && model.activeBorrowedTmuxSessionIsConnected
        }
        #expect(model.activeBorrowedTmuxSelection == shipping)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(model.activeBorrowedTmuxRecoveryState == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: shipping)?.id == handle.id)
        #expect(model.retainedBorrowedTmuxHandle(for: releaseWork) == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a terminal that is reconnecting keeps its name from a rename that takes it")
    func renameKeepsReconnectingDestination() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let hostID = environment.remoteHost.id
        let names = LockedValue(["release-work": "$2", "notes": "$3"])
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPaneSplitter: renameClientSplitter(
                names,
                launches: store.launchCommands
            ),
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { host in
                host == .local ? .success([]) : .success(renameFixture(names))
            },
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator(),
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: hostID)?.tmuxSessions
                .compactMap(\.sessionID).sorted() == ["$2", "$3"]
        }
        let releaseWork = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "release-work"
        )
        let notes = WorkspaceTmuxSessionSelection(hostID: hostID, name: "notes")
        model.openBorrowedTmuxSession(notes)
        await connectActiveRenameSession(model, store: store)
        let notesHandle = try #require(model.retainedBorrowedTmuxHandle(for: notes))
        model.openBorrowedTmuxSession(releaseWork)
        await connectActiveRenameSession(model, store: store)
        let releaseHandle = try #require(
            model.retainedBorrowedTmuxHandle(for: releaseWork)
        )

        // While release-work's SSH client is down, tmux renames it to
        // shipping and gives its old name to the notes session.
        names.store(["shipping": "$2", "release-work": "$3"])
        store.surface.closeObservers[releaseHandle.id]?(false, 255)

        let shipping = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "shipping"
        )
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.retainedBorrowedTmuxHandle(for: shipping)?.id
                == releaseHandle.id
                && model.retainedBorrowedTmuxHandle(for: releaseWork)?.id
                == notesHandle.id
        }
        #expect(
            model.retainedBorrowedTmuxHandle(for: shipping)?.id
                == releaseHandle.id
        )
        #expect(
            model.retainedBorrowedTmuxHandle(for: releaseWork)?.id
                == notesHandle.id
        )
        #expect(model.activeBorrowedTmuxSelection == shipping)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        await model.shutdown()
    }

    @MainActor
    @Test("Always Live keeps a session the user closed closed after it is renamed")
    func alwaysLiveKeepsClosedSessionClosedAcrossRename() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
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
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator(),
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let work = WorkspaceTmuxSessionSelection(hostID: hostID, name: "work")
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: desk) != nil
        }
        model.closeBorrowedTmuxSession(desk)
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)

        names.withLock { renameFixtureSession(&$0, from: "desk", to: "work") }
        model.refreshTmuxSessionDiscovery()
        // Always Live reconciles in the same pass that lists the new name.
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.map(\.name) == ["work"]
        }

        #expect(model.retainedBorrowedTmuxHandle(for: work) == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a terminal awaiting SSH sign-in keeps its recovery through a rename cycle")
    func renameKeepsRecoveryAwaitingSignIn() async throws {
        let environment = try setupRemoteTmuxEnvironment()
        let hostID = environment.remoteHost.id
        let names = LockedValue([
            "notes": "$3", "release-work": "$2", "shipping": "$4",
        ])
        let signInRequired = LockedValue(false)
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.localHostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPaneSplitter: renameClientSplitter(
                names,
                launches: store.launchCommands
            ),
            remoteTmuxPathProvider: { _, _ in
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { host in
                guard host != .local else { return .success([]) }
                guard !signInRequired.load() else {
                    return .failure(.sshConnectionFailed(
                        host: "build-box",
                        classification: SSHConnectionFailure.classify(
                            status: 255,
                            output: "Permission denied (publickey,password)."
                        )
                    ))
                }
                return .success(renameFixture(names))
            },
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator(),
            tmuxReconnectIntervals: [.milliseconds(1)]
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.host(id: hostID)?.tmuxSessions
                .compactMap(\.sessionID).count == 3
        }
        let notes = WorkspaceTmuxSessionSelection(hostID: hostID, name: "notes")
        let shipping = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "shipping"
        )
        let releaseWork = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "release-work"
        )
        var handles: [BorrowedTmuxSessionHandle] = []
        for selection in [notes, shipping, releaseWork] {
            model.openBorrowedTmuxSession(selection)
            await connectActiveRenameSession(model, store: store)
            try handles.append(#require(
                model.retainedBorrowedTmuxHandle(for: selection)
            ))
        }

        // release-work's SSH client drops and recovery waits for sign-in.
        signInRequired.store(true)
        store.surface.closeObservers[handles[2].id]?(false, 255)
        await waitUntilMainActor {
            model.sessionConnectionRecoveryRequest != nil
        }

        // tmux rotates the names, so notes wants release-work's name before
        // release-work can move.
        signInRequired.store(false)
        names.store(["shipping": "$2", "release-work": "$3", "notes": "$4"])
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: shipping)?.id == handles[2].id
                && model.retainedBorrowedTmuxHandle(for: releaseWork)?.id
                == handles[0].id
                && model.retainedBorrowedTmuxHandle(for: notes)?.id
                == handles[1].id
        }

        #expect(
            model.retainedBorrowedTmuxHandle(for: shipping)?.id == handles[2].id
        )
        #expect(
            model.retainedBorrowedTmuxHandle(for: releaseWork)?.id
                == handles[0].id
        )
        #expect(
            model.retainedBorrowedTmuxHandle(for: notes)?.id == handles[1].id
        )
        #expect(model.activeBorrowedTmuxSelection == shipping)
        #expect(model.sessionConnectionRecoveryRequest != nil)
        await model.shutdown()
    }

    @MainActor
    @Test("a detached terminal moves to its session's new name and stays detached")
    func renameKeepsDetachedTerminalDetached() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
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
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator(),
            sessionPreviewCoordinator: TmuxSessionPreviewCoordinator(
                mode: .alwaysLive,
                budget: LivePreviewBudget(limit: 0),
                capture: { _, _ in nil }
            )
        )
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let work = WorkspaceTmuxSessionSelection(hostID: hostID, name: "work")
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: desk) != nil
        }
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)
        let handle = try #require(model.retainedBorrowedTmuxHandle(for: desk))

        // The client detaches cleanly, then the session is renamed in tmux.
        store.surface.closeObservers[handle.id]?(false, 0)
        await waitUntilMainActor {
            !model.activeBorrowedTmuxSessionIsConnected
        }
        let surfaceRequests = store.requestCount
        names.withLock { renameFixtureSession(&$0, from: "desk", to: "work") }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: work)?.id == handle.id
        }

        #expect(model.retainedBorrowedTmuxHandle(for: work)?.id == handle.id)
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(model.activeBorrowedTmuxSelection == work)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(store.requestCount == surfaceRequests)
        await model.shutdown()
    }

    @MainActor
    @Test("a selected detached terminal stays when the original terminal can move")
    func renameKeepsSelectedDetachedDestination() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["anchor": "$1", "desk": "$2"])
        let sizingHold = LockedValue<DispatchGroup?>(nil)
        let identityHold = LockedValue<DispatchGroup?>(nil)
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: renameClientSplitter(
                names,
                launches: store.launchCommands,
                sizingHold: sizingHold,
                identityHold: identityHold
            ),
            tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator()
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 2
        }
        let anchor = WorkspaceTmuxSessionSelection(hostID: hostID, name: "anchor")
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let notes = WorkspaceTmuxSessionSelection(hostID: hostID, name: "notes")
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)
        let moving = try #require(model.retainedBorrowedTmuxHandle(for: desk))

        // Switching away starts a resize that holds the desk terminal in
        // place while tmux renames its session.
        let sizing = DispatchGroup()
        sizing.enter()
        sizingHold.store(sizing)
        model.openBorrowedTmuxSession(anchor)
        await connectActiveRenameSession(model, store: store)
        names.withLock { renameFixtureSession(&$0, from: "desk", to: "notes") }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.map(\.name).sorted()
                == ["anchor", "notes"]
        }
        #expect(model.retainedBorrowedTmuxHandle(for: desk)?.id == moving.id)

        // The user opens the session under its new name before tmux reports
        // that client, then detaches it.
        let identity = DispatchGroup()
        identity.enter()
        identityHold.store(identity)
        model.openBorrowedTmuxSession(notes)
        await waitUntilMainActor {
            model.prepareActiveBorrowedTmuxSurface()
            return model.activeBorrowedTmuxSelection == notes
                && model.activeBorrowedTmuxSessionIsConnected
        }
        let selected = try #require(model.retainedBorrowedTmuxHandle(for: notes))
        store.surface.closeObservers[selected.id]?(false, 0)
        await waitUntilMainActor {
            !model.activeBorrowedTmuxSessionIsConnected
        }

        // The resize finishes, so the desk terminal can move again.
        sizingHold.store(nil)
        sizing.leave()
        identityHold.store(nil)
        identity.leave()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        names.withLock { $0["extra"] = "$7" }
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 3
        }

        #expect(model.activeBorrowedTmuxSelection == notes)
        #expect(model.retainedBorrowedTmuxHandle(for: notes)?.id == selected.id)
        #expect(model.retainedBorrowedTmuxHandle(for: desk)?.id == moving.id)
        await model.shutdown()
    }

    @MainActor
    @Test("a detached terminal keeps its session through a name swap")
    func nameSwapKeepsDetachedTerminal() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2", "notes": "$3"])
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: renameClientSplitter(
                names,
                launches: store.launchCommands
            ),
            tmuxSessionDiscovery: { _ in
                .success(renameFixture(names, live: true))
            },
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator(),
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
                && model.retainedBorrowedTmuxHandle(for: notes) != nil
        }
        model.openBorrowedTmuxSession(notes)
        await connectActiveRenameSession(model, store: store)
        let wasNotes = try #require(model.retainedBorrowedTmuxHandle(for: notes))
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)
        let wasDesk = try #require(model.retainedBorrowedTmuxHandle(for: desk))

        // desk's client detaches cleanly, then the two sessions swap names.
        store.surface.closeObservers[wasDesk.id]?(false, 0)
        await waitUntilMainActor {
            !model.activeBorrowedTmuxSessionIsConnected
        }
        let surfaceRequests = store.requestCount
        names.store(["desk": "$3", "notes": "$2"])
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: notes)?.id == wasDesk.id
                && model.retainedBorrowedTmuxHandle(for: desk)?.id
                == wasNotes.id
        }

        #expect(model.retainedBorrowedTmuxHandle(for: notes)?.id == wasDesk.id)
        #expect(model.retainedBorrowedTmuxHandle(for: desk)?.id == wasNotes.id)
        #expect(model.activeBorrowedTmuxSelection == notes)
        #expect(!model.activeBorrowedTmuxSessionIsConnected)
        #expect(store.requestCount == surfaceRequests)
        await model.shutdown()
    }

    @MainActor
    @Test("a listing whose kwt pass failed still follows a rename made in tmux")
    func partialListingFollowsTmuxRename() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
        let kwtFails = LockedValue(false)
        let store = SceneTmuxSurfaceStoreStub()
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            tmuxSessionDiscovery: { _ in
                let sessions = renameFixture(names)
                return kwtFails.load()
                    ? .failure(.kwtDiscoveryFailed(sessions: sessions, status: 1))
                    : .success(sessions)
            },
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator()
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 1
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        model.openBorrowedTmuxSession(desk)
        await connectActiveRenameSession(model, store: store)
        let handle = try #require(model.retainedBorrowedTmuxHandle(for: desk))

        names.withLock { renameFixtureSession(&$0, from: "desk", to: "work") }
        kwtFails.store(true)
        model.refreshTmuxSessionDiscovery()

        let work = WorkspaceTmuxSessionSelection(hostID: hostID, name: "work")
        await waitUntilMainActor {
            model.retainedBorrowedTmuxHandle(for: work)?.id == handle.id
        }
        #expect(model.retainedBorrowedTmuxHandle(for: work)?.id == handle.id)
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(model.activeBorrowedTmuxSelection == work)
        #expect(model.activeBorrowedTmuxSessionIsConnected)
        #expect(store.removedKeys.isEmpty)
        await model.shutdown()
    }

    @MainActor
    @Test("rename refuses a session that took the name while the sheet was open")
    func renameRefusesReplacedSession() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["desk": "$2"])
        let renames = LockedValue(0)
        let model = try makeModel(
            database: environment.database,
            localHostID: hostID,
            snapshot: environment.snapshot,
            tmuxSessionDiscovery: { _ in .success(renameFixture(names)) },
            tmuxSessionRenamer: { _, _, _, _ in
                renames.withLock { $0 += 1 }
            },
            tmuxSessionRenameCoordinator: TmuxSessionRenameCoordinator()
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.first?.sessionID == "$2"
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        let request = try #require(
            WorkspaceSidebarModel.renameRequest(desk, in: model.snapshot)
        )

        // While the sheet is open, desk ends and a new session takes its name.
        names.store(["desk": "$9"])
        model.refreshTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.first?.sessionID == "$9"
        }

        await #expect {
            try await model.renameTmuxSession(request, to: "work")
        } throws: { error in
            error as? TmuxSessionRenameError == .sessionChanged(
                host: "localhost",
                session: "desk"
            )
        }
        #expect(renames.load() == 0)
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
        await #expect {
            try await model.renameTmuxSession(
                WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk"),
                to: "has.period"
            )
        } throws: { error in
            error as? TmuxSessionRenameError == .invalidName(name: "has.period")
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

/// Reports the fixture's first session as the one each client attached to,
/// once `reported` has been left.
private func renameIdentitySplitter(
    _ sessions: LockedValue<[String: String]>,
    after reported: DispatchGroup? = nil
) -> TmuxPaneSplitter {
    TmuxPaneSplitter { _, _, command in
        guard command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") else {
            return (0, "")
        }
        reported?.wait()
        guard let sessionID = sessions.load().sorted(by: { $0.key < $1.key })
            .first?.value
        else { return (0, "") }
        return (
            0,
            "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                + "\t101\t789\t321\t/dev/ttys001\t\(sessionID)\t1000\t%9\n"
        )
    }
}

/// The tmux clients a fake splitter has seen, by launch client token.
private final class RenameTmuxClients: Sendable {
    /// The session each client attached to, by session ID.
    let attached = LockedValue<[String: String]>([:])
    /// Each client's TTY, by token.
    let ttys = LockedValue<[String: String]>([:])
    /// TTYs of clients that tmux detached.
    let detached = LockedValue<Set<String>>([])
    /// The kept client has switched sessions, so tmux refuses to detach a
    /// duplicate.
    let keeperSwitched = LockedValue(false)
    let refusedDetaches = LockedValue(0)
    /// Detaches stalled by `detachHold`, and those running without it.
    let heldDetaches = LockedValue(0)
    let unheldDetaches = LockedValue(0)
    /// Stalls detach commands while set.
    let detachHold = LockedValue<DispatchGroup?>(nil)
    /// The session a detached-only-if-shared client is on now has another
    /// client.
    let sessionShared = LockedValue(false)

    func tty(for token: String) -> String {
        var tty = ""
        ttys.withLock { ttys in
            tty = ttys[token] ?? "/dev/ttys\(100 + ttys.count)"
            ttys[token] = tty
        }
        return tty
    }

    /// Like the real guard, refuses unless the kept client, whose TTY the
    /// guard names last, is still attached.
    func detach(_ command: String) -> String {
        if let hold = detachHold.load() {
            heldDetaches.withLock { $0 += 1 }
            hold.wait()
            return decideDetach(command)
        }
        unheldDetaches.withLock { $0 += 1 }
        defer { unheldDetaches.withLock { $0 -= 1 } }
        return decideDetach(command)
    }

    private func decideDetach(_ command: String) -> String {
        let pattern = "/dev/ttys[0-9]+"
        let keeper = command.ranges(of: try! Regex(pattern)).last
            .map { String(command[$0]) }
        let duplicate = command.range(of: "detach-client").flatMap {
            command[$0.upperBound...].range(
                of: pattern,
                options: .regularExpression
            )
        }.map { String(command[$0]) }
        var allowed = false
        if command.contains("session_attached") {
            if let duplicate, sessionShared.load() {
                detached.withLock { $0.insert(duplicate) }
                allowed = true
            }
        } else if let keeper, let duplicate, !keeperSwitched.load() {
            detached.withLock { detached in
                guard !detached.contains(keeper) else { return }
                detached.insert(duplicate)
                allowed = true
            }
        }
        guard !allowed else { return "" }
        refusedDetaches.withLock { $0 += 1 }
        return (command.range(
            of: "GHOSTHUB_TMUX_CLIENT_DETACH_REFUSED_[0-9A-F-]{36}",
            options: .regularExpression
        ).map { String(command[$0]) } ?? "") + "\n"
    }

    static func token(in command: String) -> String? {
        command.range(
            of: "[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}",
            options: .regularExpression
        ).map { String(command[$0]) }
    }
}

/// Reports each client as attached to the session its `attach-session`
/// targeted when tmux was first asked, and to that same session after any
/// rename. A launch that names a session no longer listed attaches to
/// nothing. The
/// identity command carries the launch's client token. The holds stall
/// resize and identity commands while set.
private func renameClientSplitter(
    _ sessions: LockedValue<[String: String]>,
    launches: LockedValue<[String]>,
    clients: RenameTmuxClients = RenameTmuxClients(),
    sizingHold: LockedValue<DispatchGroup?> = LockedValue(nil),
    identityHold: LockedValue<DispatchGroup?> = LockedValue(nil)
) -> TmuxPaneSplitter {
    TmuxPaneSplitter { _, _, command in
        if command.contains("ignore-size") {
            sizingHold.load()?.wait()
        }
        if command.contains("detach-client") {
            return (0, clients.detach(command))
        }
        guard command.contains("GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY") else {
            return (0, "")
        }
        identityHold.load()?.wait()
        guard let token = RenameTmuxClients.token(in: command) else {
            return (0, "")
        }
        if clients.attached.load()[token] == nil,
           let launch = launches.load().last(where: { $0.contains(token) }) {
            let listed = sessions.load()
            let sessionID: String? = switch attachTarget(in: launch) {
            case let target? where target.hasPrefix("="):
                listed[String(target.dropFirst())]
            case let target? where listed.values.contains(target):
                target
            default:
                nil
            }
            clients.attached.withLock { $0[token] = sessionID }
        }
        guard let sessionID = clients.attached.load()[token] else {
            return (0, "")
        }
        let tty = clients.tty(for: token)
        return (
            0,
            "GHOSTHUB_TMUX_SPLIT_CLIENT_IDENTITY"
                + "\t101\t\(tty.dropFirst(9))\t321\t\(tty)\t\(sessionID)\t1000\t%9\n"
        )
    }
}

/// The target of the launch's `attach-session`. Setup commands in the same
/// launch target the session too, so they must not count as the attach.
private func attachTarget(in launch: String) -> String? {
    let unquoted = launch.filter { !"\\'\"".contains($0) }
    guard let attach = unquoted.range(of: "attach-session ") else {
        return nil
    }
    let words = unquoted[attach.upperBound...].split(separator: " ")
    guard let flag = words.firstIndex(of: "-t"),
          words.indices.contains(flag + 1)
    else { return nil }
    return String(words[flag + 1])
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
private extension WorkspaceSceneModel {
    /// Opens the rename sheet for `selection` and submits `name` at once.
    func renameTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection,
        to name: String
    ) async throws {
        guard let request = WorkspaceSidebarModel.renameRequest(
            selection,
            in: snapshot
        ) else {
            throw TmuxSessionRenameError.sessionNotRunning(
                host: "",
                session: selection.name
            )
        }
        try await renameTmuxSession(request, to: name)
    }
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
