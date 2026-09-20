import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

struct HostOrderingTests {
    @MainActor
    @Test("saved sidebar order is shared with Settings and survives inventory refresh")
    func sharedHostOrder() throws {
        let local = HostSummary.fixture(kind: .selfHost)
        let first = SSHHostDraft(
            configKey: "first",
            name: "First",
            platform: .linux,
            sshDestination: "first.example.test"
        )
        let second = SSHHostDraft(
            configKey: "second",
            name: "Second",
            platform: .linux,
            sshDestination: "second.example.test"
        )
        let hosts = [local] + [first, second].map { draft in
            HostSummary(
                id: UUID(),
                configKey: draft.configKey,
                name: draft.name,
                kind: .remote,
                platform: draft.platform
            )
        }
        let cache = WorkspaceSidebarSectionCache()
        let snapshot = WorkspaceSnapshot.fixture(hosts: hosts)
        let initial = cache.sections(in: snapshot, snapshotRevision: 0)
        var order = WorkspaceSidebarOrder()
        let moved = order.move(
            WorkspaceSidebarModel.hostOrderID(hosts[2]),
            to: WorkspaceSidebarModel.hostOrderID(local),
            within: initial.map { WorkspaceSidebarModel.hostOrderID($0.host) }
        )
        #expect(moved)

        let suite = "ghosthub.host-order.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(order.rawValue, forKey: WorkspaceSidebarOrderStorage.hostKey)
        let savedOrder = WorkspaceSidebarOrderStorage.hostRawValue(in: defaults)
        #expect(cache.sections(
            in: snapshot,
            snapshotRevision: 0,
            hostOrderRawValue: savedOrder
        ).map(\.host.id)
            == [hosts[2].id, local.id, hosts[1].id])
        let settingsHosts = WorkspaceSidebarModel.orderedSettingsHosts(
            [first, second], hostOrderRawValue: savedOrder
        )
        #expect(settingsHosts.map(\.id) == ["host:second", "local", "host:first"])
        order.move(
            fromOffsets: IndexSet(integer: 1), toOffset: 3,
            within: settingsHosts.map(\.id)
        )
        #expect(cache.sections(
            in: snapshot, snapshotRevision: 0, hostOrderRawValue: order.rawValue
        ).map(\.host.id) == [hosts[2].id, hosts[1].id, local.id])

        let refreshed = HostSummary(
            id: UUID(),
            configKey: "second",
            name: "Renamed",
            kind: .remote,
            platform: .linux,
            lastKnownReachable: false
        )
        let added = HostSummary(
            id: UUID(),
            configKey: "new",
            name: "New",
            kind: .remote,
            platform: .linux
        )
        let next = WorkspaceSnapshot.fixture(hosts: [local, hosts[1], refreshed, added])
        #expect(cache.sections(
            in: next,
            snapshotRevision: 1,
            hostOrderRawValue: savedOrder
        ).map(\.host.id)
            == [refreshed.id, local.id, hosts[1].id, added.id])
    }

    @Test("Settings moves preserve the positions of hosts outside its list")
    func settingsMove() {
        var order = WorkspaceSidebarOrder(rawValue: "host:first\nlocal\nhost:vm\nhost:second")
        order.move(
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0,
            within: ["host:first", "host:second"]
        )
        #expect(order.rawValue == "host:second\nlocal\nhost:vm\nhost:first")
    }

    @Test("the first Settings move can put a remote host above Local Mac")
    func firstSettingsMove() throws {
        let suite = "ghosthub.host-order.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var order = WorkspaceSidebarOrder(
            rawValue: WorkspaceSidebarOrderStorage.hostRawValue(in: defaults)
        )
        order.move(
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0,
            within: ["local", "host:first", "host:second"]
        )
        #expect(order.rawValue == "host:first\nlocal\nhost:second")
    }

    @Test("Settings includes Local Mac without configured SSH hosts")
    func localOnly() {
        #expect(WorkspaceSidebarModel.orderedSettingsHosts(
            [], hostOrderRawValue: "host:removed\nlocal"
        ).map(\.id) == ["local"])
    }

    @Test("new hosts do not inherit positions from removed or unsaved drafts")
    func reusedConfigurationKey() throws {
        let old = SSHHostDraft(
            configKey: "host",
            name: "Old",
            platform: .linux,
            sshDestination: "old.example.test"
        )
        let kept = SSHHostDraft(
            configKey: "host-2",
            name: "Kept",
            platform: .linux,
            sshDestination: "kept.example.test"
        )
        let saved = "host:host\nlocal\nhost:host-2"
        let removed = SSHHostDraftListEditor.removingSelectedHost(
            from: [old, kept], selectedDraftID: old.id
        )
        #expect(WorkspaceSidebarModel.updatingHostOrder(
            saved, from: [old, kept], to: removed.drafts
        ) == "local\nhost:host-2")

        let added = SSHHostDraftListEditor.addingDefaultHost(to: [kept])
        let newHost = try #require(added.drafts.last)
        #expect(newHost.configKey == old.configKey)
        // A discarded, invalid draft may have left an order entry without
        // a saved connection. Adding the same key still appends the new host.
        let order = WorkspaceSidebarModel.updatingHostOrder(
            saved, from: [kept], to: added.drafts
        )
        #expect(WorkspaceSidebarModel.orderedSettingsHosts(
            added.drafts, hostOrderRawValue: order
        ).compactMap(\.sshHost).map(\.id) == [kept.id, newHost.id])
    }
}
