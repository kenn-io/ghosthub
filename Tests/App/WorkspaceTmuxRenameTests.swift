import Foundation
import GhosthubTmux
@testable import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

extension WorkspaceTmuxDiscoveryTests {
    @MainActor
    @Test("renaming the open session reattaches it under the new name")
    func renameReattachesOpenSession() async throws {
        let environment = try setupStandardEnvironment()
        let hostID = environment.host.id
        let names = LockedValue(["anchor", "desk"])
        let renames = LockedValue<[(String, String, TmuxSessionIdentity)]>([])
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
            tmuxSessionDiscovery: { _ in
                .success(names.load().map { name in
                    DiscoveredTmuxSession(
                        name: name,
                        windowCount: 1,
                        serverPID: "101",
                        sessionID: name == "anchor" ? "$1" : "$2",
                        createdAt: "1000",
                        managed: false
                    )
                })
            },
            tmuxSessionRenamer: { selection, newName, identity, _ in
                renames.withLock {
                    $0.append((selection.name, newName, identity))
                }
                names.withLock { names in
                    names = names.map { $0 == selection.name ? newName : $0 }
                }
            },
            sidebarOrderDefaults: defaults
        )
        model.startTmuxSessionDiscovery()
        await waitUntilMainActor {
            model.snapshot.hosts[0].tmuxSessions.count == 2
        }
        let desk = WorkspaceTmuxSessionSelection(hostID: hostID, name: "desk")
        model.openBorrowedTmuxSession(desk)
        #expect(model.activeBorrowedTmuxSelection?.name == "desk")

        try await model.renameTmuxSession(desk, to: "  work  ")

        let recorded = renames.load()
        #expect(recorded.count == 1)
        #expect(recorded.first?.0 == "desk")
        #expect(recorded.first?.1 == "work")
        #expect(recorded.first?.2 == TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$2",
            createdAt: "1000"
        ))
        #expect(
            Set(model.snapshot.hosts[0].tmuxSessions.map(\.name))
                == ["anchor", "work"]
        )
        let work = WorkspaceTmuxSessionSelection(hostID: hostID, name: "work")
        #expect(model.activeBorrowedTmuxSelection == work)
        #expect(model.retainedBorrowedTmuxHandle(for: desk) == nil)
        #expect(model.retainedBorrowedTmuxHandle(for: work) != nil)
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
        await model.shutdown()
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
