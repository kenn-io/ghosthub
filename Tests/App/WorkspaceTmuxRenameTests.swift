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
    @Test("rename refuses taken names and kwt-owned sessions without running tmux")
    func renameRefusesTakenAndOwnedNames() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
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
            snapshot: environment.snapshot,
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
        #expect(renames.load() == 0)
        #expect(
            model.snapshot.hosts[0].tmuxSessions.map(\.name).sorted()
                == ["anchor", "desk", "managed"]
        )
        await model.shutdown()
    }
}

private func renameFixture(
    _ sessions: LockedValue<[String: String]>
) -> [DiscoveredTmuxSession] {
    sessions.load().sorted { $0.key < $1.key }.map { name, sessionID in
        DiscoveredTmuxSession(
            name: name,
            windowCount: 1,
            serverPID: "101",
            sessionID: sessionID,
            createdAt: "1000",
            managed: false
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
