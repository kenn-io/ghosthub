import Combine
import Foundation
import GhosthubTestSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubUI

@MainActor
struct WorktreeFlagStoreTests {
    @Test("row observers share a key without retaining detached rows")
    func rowObservation() throws {
        let fixture = try FlagStoreFixture()
        let store = fixture.store()
        let key = try #require(FlagTestWorkspace().key)
        weak var released: WorktreeFlagState?
        do {
            let state = store.state(for: key)
            released = state
            #expect(store.state(for: key) === state)
            #expect(!state.isFlagged)
            try store.setFlagged(true, for: key)
            #expect(state.isFlagged)
            #expect(!store.state(for: nil).isFlagged)
        }
        #expect(released == nil)
        #expect(store.state(for: key).isFlagged)
    }

    @Test("flags restore and explicit updates are idempotent")
    func persistence() throws {
        let fixture = try FlagStoreFixture()
        let key = try #require(FlagTestWorkspace().key)
        let store = fixture.store()
        #expect(store.flaggedKeys.isEmpty)
        try store.setFlagged(true, for: key)
        let saved = fixture.defaults.data(forKey: WorktreeFlagStore.preferenceKey)
        try store.setFlagged(true, for: key)
        #expect(fixture.defaults.data(forKey: WorktreeFlagStore.preferenceKey) == saved)
        #expect(fixture.store().isFlagged(key))
        try store.setFlagged(false, for: key)
        #expect(fixture.store().flaggedKeys.isEmpty)
    }

    @Test("two observers share updates without losing another window's flags")
    func sharedUpdates() throws {
        let fixture = try FlagStoreFixture()
        let store = fixture.store()
        let first = try #require(FlagTestWorkspace().key)
        var secondWorkspace = FlagTestWorkspace()
        secondWorkspace.snapshot.worktrees[0].generation = String(repeating: "b", count: 32)
        let second = try #require(secondWorkspace.key)
        var firstValues: [Set<WorktreeFlagKey>] = []
        var secondValues: [Set<WorktreeFlagKey>] = []
        let a = store.$flaggedKeys.sink { firstValues.append($0) }
        let b = store.$flaggedKeys.sink { secondValues.append($0) }
        try store.setFlagged(true, for: first)
        try store.setFlagged(true, for: second)
        try store.setFlagged(true, for: second)
        #expect(firstValues == [[], [first], [first, second]])
        #expect(secondValues == firstValues)
        #expect(fixture.store().flaggedKeys == [first, second])
        withExtendedLifetime((a, b)) {}
    }

    @Test("lookup uses memory and never serializes, even for a large flag set")
    func lookupDoesNotPersist() throws {
        let fixture = try FlagStoreFixture()
        let keys = (0 ..< 2000).map {
            WorktreeFlagKey(
                hostKey: "local", projectKey: "repo-\($0)",
                generation: String(repeating: "a", count: 32)
            )!
        }
        fixture.defaults.set(
            try JSONEncoder().encode(keys),
            forKey: WorktreeFlagStore.preferenceKey
        )
        var encodes = 0
        let store = WorktreeFlagStore(userDefaults: fixture.defaults, encode: {
            encodes += 1
            return try WorktreeFlagStore.encode($0)
        }, reportDiagnostic: { _ in })
        fixture.defaults.removeObject(forKey: WorktreeFlagStore.preferenceKey)
        for _ in 0 ..< 5 {
            for key in keys {
                #expect(store.isFlagged(key))
            }
        }
        #expect(encodes == 0)
        #expect(fixture.defaults.object(forKey: WorktreeFlagStore.preferenceKey) == nil)
    }

    @Test("loading skips invalid entries and duplicates without rewriting bytes")
    func malformedEntries() throws {
        let fixture = try FlagStoreFixture()
        let key = try #require(FlagTestWorkspace().key)
        let entry = String(decoding: try JSONEncoder().encode(key), as: UTF8.self)
        let bytes = Data("[\(entry),null,\(entry),{\"generation\":\"bad\"}]".utf8)
        fixture.defaults.set(bytes, forKey: WorktreeFlagStore.preferenceKey)
        var diagnostics: [String] = []
        let store = fixture.store(reportDiagnostic: { diagnostics.append($0) })
        #expect(store.flaggedKeys == [key])
        #expect(diagnostics.count == 1)
        #expect(fixture.defaults.data(forKey: WorktreeFlagStore.preferenceKey) == bytes)
    }

    @Test("unreadable state is diagnosed once and replaced only by an explicit update")
    func malformedDocument() throws {
        let fixture = try FlagStoreFixture()
        let bytes = Data("not-json".utf8)
        fixture.defaults.set(bytes, forKey: WorktreeFlagStore.preferenceKey)
        var diagnostics: [String] = []
        let store = fixture.store(reportDiagnostic: { diagnostics.append($0) })
        #expect(store.flaggedKeys.isEmpty)
        #expect(diagnostics.count == 1)
        #expect(fixture.defaults.data(forKey: WorktreeFlagStore.preferenceKey) == bytes)
        let key = try #require(FlagTestWorkspace().key)
        try store.setFlagged(true, for: key)
        #expect(fixture.store().isFlagged(key))
    }

    @Test("serialization order is independent of toggle order")
    func deterministicStorage() throws {
        let a = try FlagStoreFixture()
        let b = try FlagStoreFixture()
        let keys = ["repo-b", "repo-a"].map {
            WorktreeFlagKey(
                hostKey: "local",
                projectKey: $0,
                generation: String(repeating: "a", count: 32)
            )!
        }
        let first = a.store()
        let second = b.store()
        for key in keys {
            try first.setFlagged(true, for: key)
        }
        for key in keys.reversed() {
            try second.setFlagged(true, for: key)
        }
        #expect(a.defaults.data(forKey: WorktreeFlagStore.preferenceKey)
            == b.defaults.data(forKey: WorktreeFlagStore.preferenceKey))
    }

    @Test("primary and linked checkouts use durable identity", arguments: [true, false])
    func primaryIdentity(_ primary: Bool) throws {
        var workspace = FlagTestWorkspace()
        workspace.snapshot.worktrees[0].isPrimary = primary
        let original = try #require(workspace.key)
        workspace.snapshot.hosts[0].name = "Renamed host"
        workspace.snapshot.hosts[0].lastKnownReachable = false
        workspace.snapshot.worktrees[0].branch = "renamed-branch"
        #expect(workspace.key == original)
        let old = workspace.snapshot.worktrees[0]
        workspace.snapshot.worktrees[0] = .fixture(
            hostID: old.hostID, projectID: old.projectID,
            generation: old.generation
        )
        #expect(workspace.key == original)
        workspace.snapshot.worktrees[0].generation = String(repeating: "b", count: 32)
        #expect(workspace.key != original)
    }

    @Test("host and project namespaces isolate the same generation")
    func identityNamespaces() throws {
        var workspace = FlagTestWorkspace()
        let local = try #require(workspace.key)
        workspace.snapshot.hosts[0].kind = .remote
        workspace.snapshot.hosts[0].configKey = "build-box"
        let remote = try #require(workspace.key)
        #expect(remote != local)
        workspace.snapshot.projects[0].scopedKey = "github.com/example/other"
        #expect(workspace.key != remote)
    }

    @Test("missing or noncanonical generations have no persistent identity", arguments: [
        nil, "", "legacy", String(repeating: "A", count: 32), String(repeating: "a", count: 31),
    ] as [String?])
    func invalidGenerations(_ generation: String?) {
        var workspace = FlagTestWorkspace()
        workspace.snapshot.worktrees[0].generation = generation
        #expect(workspace.key == nil)
    }

    @Test("missing owners and empty stable keys do not resolve")
    func missingOwners() {
        var workspace = FlagTestWorkspace()
        workspace.snapshot.projects[0].scopedKey = ""
        #expect(workspace.key == nil)
        workspace = FlagTestWorkspace()
        workspace.snapshot.projects[0].hostID = UUID()
        #expect(workspace.key == nil)
        workspace = FlagTestWorkspace()
        workspace.snapshot.hosts[0].kind = .remote
        #expect(workspace.key == nil)
        workspace.snapshot.hosts = []
        #expect(workspace.key == nil)
        workspace.snapshot.worktrees = []
        #expect(workspace.key == nil)
    }
}

struct FlagTestWorkspace {
    var snapshot: WorkspaceSnapshot
    var worktreeID: UUID { snapshot.worktrees[0].id }
    var key: WorktreeFlagKey? {
        guard let worktree = snapshot.worktrees.first else { return nil }
        return WorktreeFlagKey.resolve(worktreeID: worktree.id, in: snapshot)
    }

    init() {
        let host = HostSummary.fixture()
        var project = ProjectSummary.fixture(hostID: host.id)
        project.scopedKey = "github.com/example/project"
        let worktree = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id,
            generation: String(repeating: "a", count: 32)
        )
        snapshot = .fixture(hosts: [host], projects: [project], worktrees: [worktree])
    }
}

@MainActor
final class FlagStoreFixture {
    let defaults: UserDefaults
    private let suite: String

    init() throws {
        suite = "worktree-flags-tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    func store(reportDiagnostic: @escaping (String) -> Void = { _ in }) -> WorktreeFlagStore {
        WorktreeFlagStore(userDefaults: defaults, reportDiagnostic: reportDiagnostic)
    }
}
