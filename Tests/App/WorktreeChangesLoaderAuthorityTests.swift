import Combine
import Foundation
import GhosthubPersistence
import GhosthubSettings
import GhosthubTransport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("worktree changes loader authority")
struct WorktreeChangesLoaderAuthorityTests {
    @MainActor
    @Test("malformed successful inspection waits for manual refresh", arguments: [
        "GHOSTHUB_KWT_JSON\nnot-json", "missing marker",
    ])
    func malformedInspectionStopsPolling(output: String) async throws {
        let fixture = makeFixture()
        let reads = LockedValue(0)
        let client = KwtWorktreeClient(localRunner: { _, _ in
            reads.withLock { $0 += 1 }
            return (0, output)
        })
        let identity = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: fixture.worktree.id, in: fixture.snapshot
        ))
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)
        for _ in 0 ..< 2 {
            await WorktreeChangesPollLoop.run(
                identity: identity, worktree: fixture.worktree, store: store,
                currentSnapshot: { fixture.snapshot }, isEligible: { true },
                load: { worktree in
                    try await client.changes(
                        worktreePath: worktree.path,
                        expectedRepository: identity.repository,
                        expectedGeneration: identity.generation, on: .local
                    )
                },
                sleep: { _ in
                    Issue.record("Malformed inspection must not schedule a retry")
                    throw CancellationError()
                }
            )
        }
        #expect(reads.load() == 1)
        #expect(store.entry(for: identity).requiresManualRefresh)
    }

    @MainActor
    @Test(
        "registration changes stop stale polling until inventory supplies a new identity",
        arguments: [false, true]
    )
    func registrationChangeWaitsForInventoryRefresh(manualRefreshDuringRead: Bool) async throws {
        let fixture = makeFixture()
        var snapshot = fixture.snapshot
        let oldGeneration = try #require(fixture.worktree.generation)
        let newGeneration = String(repeating: "f", count: 32)
        let reads = LockedValue<[String]>([])
        let delays = LockedValue<[Duration]>([])
        let client = KwtWorktreeClient(localRunner: { _, command in
            if command.contains(oldGeneration) {
                return (1, """
                GHOSTHUB_KWT_JSON
                {"error":{"code":"registration_changed","message":"Worktree registration changed.","retryable":true}}
                """)
            }
            return (0, """
            GHOSTHUB_KWT_JSON
            {"worktree":{"repository":"\(fixture.project.scopedKey)","path":"\(fixture.worktree
                .path)","generation":"\(
                newGeneration
            )"},"changes":{"state":"clean","summary":{"modified":0,"added":0,"deleted":0,"untracked":0,"staged":0,"conflicts":0},"files":[]},"observed_at":"now"}
            """)
        })
        let store = WorktreeChangesStore()
        store.setExpanded(true, worktreeID: fixture.worktree.id)
        let oldIdentity = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: fixture.worktree.id, in: snapshot
        ))
        let poll = {
            let worktree = snapshot.worktrees[0]
            let identity = try #require(WorktreeChangesIdentity.resolve(
                worktreeID: worktree.id, in: snapshot
            ))
            await WorktreeChangesPollLoop.run(
                identity: identity, worktree: worktree, store: store,
                currentSnapshot: { snapshot }, isEligible: { true },
                load: { requested in
                    let generation = try #require(requested.generation)
                    reads.withLock { $0.append(generation) }
                    if manualRefreshDuringRead, generation == oldGeneration {
                        await MainActor.run {
                            store.requestManualRefresh(for: oldIdentity, refreshInventory: {
                                Issue.record("The in-flight read has not failed yet")
                            })
                        }
                    }
                    return try await client.changes(
                        worktreePath: requested.path,
                        expectedRepository: fixture.project.scopedKey,
                        expectedGeneration: generation, on: .local
                    )
                },
                sleep: { duration in
                    delays.withLock { $0.append(duration) }
                    throw CancellationError()
                }
            )
        }

        try await poll()
        try await poll()
        #expect(reads.load() == [oldGeneration])
        #expect(delays.load().isEmpty)
        #expect(store.entry(for: oldIdentity).requiresManualRefresh)
        #expect(!store.entry(for: oldIdentity).isLoading)
        #expect(store.entry(for: oldIdentity).errorMessage?
            .contains("Refresh workspace inventory") == true)

        store.requestManualRefresh(for: oldIdentity, refreshInventory: {
            snapshot.worktrees[0].generation = newGeneration
        })
        let newIdentity = try #require(WorktreeChangesIdentity.resolve(
            worktreeID: fixture.worktree.id, in: snapshot
        ))
        store.prune(keeping: [newIdentity])
        try await poll()
        #expect(reads.load() == [oldGeneration, newGeneration])
        #expect(store.entry(for: newIdentity).hasSuccessfulValue)
        #expect(!store.entry(for: newIdentity).requiresManualRefresh)
    }

    @Test("current inventory supplies the exact guarded target")
    func currentTarget() async throws {
        let fixture = makeFixture()
        let recorded = LockedValue<ReadArguments?>(nil)
        let expected = WorktreeFileChanges(
            repository: fixture.project.scopedKey,
            path: fixture.worktree.path,
            generation: fixture.worktree.generation!,
            state: .clean,
            summary: .clean,
            files: [],
            observedAt: "now"
        )

        let result = try await WorktreeChangesLoaderAuthority.load(
            requested: fixture.worktree,
            in: fixture.snapshot,
            read: { path, repository, generation, _, host in
                recorded.store(ReadArguments(
                    path: path,
                    repository: repository,
                    generation: generation,
                    host: host
                ))
                return expected
            }
        )

        #expect(result == expected)
        #expect(recorded.load()?.path == fixture.worktree.path)
        #expect(recorded.load()?.repository == fixture.project.scopedKey)
        #expect(recorded.load()?.generation == fixture.worktree.generation)
        #expect(recorded.load()?.host == .local)
    }

    @Test("changed inventory rejects the request before reading")
    func changedTarget() async {
        let fixture = makeFixture()
        var changed = fixture.snapshot
        changed.worktrees[0].path = "/repo/replaced"
        let reads = LockedValue(0)

        await #expect(throws: KwtWorktreeError.worktreeUnavailable) {
            _ = try await WorktreeChangesLoaderAuthority.load(
                requested: fixture.worktree,
                in: changed,
                read: { _, _, _, _, _ in
                    reads.withLock { $0 += 1 }
                    throw KwtWorktreeError.commandFailed(
                        host: "unexpected",
                        status: 1
                    )
                }
            )
        }
        #expect(reads.load() == 0)
    }

    @Test("remote loads provision kwt before reading changes")
    @MainActor
    func remoteLoadProvisionsKwt() async throws {
        let fixture = makeFixture()
        let localHost = HostSummary.fixture()
        var remoteHost = fixture.snapshot.hosts[0]
        remoteHost.kind = .remote
        remoteHost.platform = .linux
        remoteHost.sshDestination = "user-a@builder.example.test"
        var snapshot = fixture.snapshot
        snapshot.hosts = [localHost, remoteHost]
        let events = LockedValue<[String]>([])
        let expected = WorktreeFileChanges(
            repository: fixture.project.scopedKey,
            path: fixture.worktree.path,
            generation: fixture.worktree.generation!,
            state: .clean,
            summary: .clean,
            files: [],
            observedAt: "now"
        )
        let model = try makeModel(
            database: try WorkspaceDatabase.inMemory(),
            localHostID: localHost.id,
            snapshot: snapshot,
            kwtRemoteProvisioner: { _ in
                events.withLock { $0.append("provision") }
            },
            kwtWorktreeChangesReader: { _, _, _, routeIdentity, _ in
                events.withLock { $0.append("read") }
                #expect(routeIdentity == "sha256:test-route")
                return expected
            }
        )

        let result = try await model.loadWorktreeChanges(fixture.worktree)

        #expect(result == expected)
        #expect(events.load() == ["provision", "read"])
        await model.shutdown()
    }

    @MainActor
    @Test(
        "changed-file loads reject hosts changed during provisioning even after inventory returns",
        arguments: [
            ("user-a@builder.example.test:2222", HostPlatform.linux),
            ("user-a@builder.example.test", HostPlatform.macOS),
        ]
    )
    func hostChangedDuringProvisioning(destination: String, platform: HostPlatform) async throws {
        let fixture = makeFixture()
        let localHost = HostSummary.fixture()
        var remoteHost = fixture.snapshot.hosts[0]
        remoteHost.kind = .remote
        remoteHost.platform = .linux
        remoteHost.configKey = "builder"
        remoteHost.sshDestination = "user-a@builder.example.test"
        let configuredHost = SSHHost(
            configKey: remoteHost.configKey, name: remoteHost.name,
            platform: remoteHost.platform,
            sshDestination: try #require(remoteHost.sshDestination)
        )
        let configuredHosts = CurrentValueSubject<[SSHHost], Never>([configuredHost])
        let inventory = WorkspaceTmuxTestSupport.inventory(
            project: fixture.project, worktrees: [fixture.worktree]
        )
        let snapshot = KwtSnapshotMerger.merge(
            inventory, hostID: remoteHost.id,
            into: .fixture(hosts: [localHost, remoteHost])
        )
        let worktree = try #require(snapshot.worktrees.first)
        let provisioningGate = AsyncGate()
        let reads = LockedValue(0)
        let model = try makeModel(
            database: try WorkspaceDatabase.inMemory(),
            localHostID: localHost.id,
            snapshot: snapshot,
            kwtRemoteProvisioner: { host in
                #expect(host == configuredHost)
                await provisioningGate.wait()
            },
            kwtWorktreeChangesReader: { path, repository, generation, _, _ in
                reads.withLock { $0 += 1 }
                return WorktreeFileChanges(
                    repository: repository, path: path, generation: generation,
                    state: .clean, summary: .clean, files: [], observedAt: "now"
                )
            },
            configuredSSHHostsProvider: { configuredHosts.value }
        )
        let read = Task { try await model.loadWorktreeChanges(worktree) }
        await provisioningGate.waitUntilWaiting()
        configuredHosts.send([SSHHost(
            configKey: configuredHost.configKey, name: configuredHost.name,
            platform: platform, sshDestination: destination
        )])
        model.refreshHosts()
        #expect(model.snapshot.worktrees.isEmpty)
        model.snapshot = KwtSnapshotMerger.merge(
            inventory, hostID: remoteHost.id, into: model.snapshot
        )
        #expect(model.snapshot.worktree(id: worktree.id)?.generation == worktree.generation)
        provisioningGate.open()

        await #expect(throws: KwtWorktreeError.worktreeUnavailable) {
            try await read.value
        }
        #expect(reads.load() == 0)
        await model.shutdown()
    }

    @Test("permanent provisioning failures stop automatic retries")
    @MainActor
    func permanentProvisioningFailureIsNotRetryable() async throws {
        let fixture = makeFixture()
        let localHost = HostSummary.fixture()
        var remoteHost = fixture.snapshot.hosts[0]
        remoteHost.kind = .remote
        remoteHost.platform = .linux
        remoteHost.sshDestination = "user-a@builder.example.test"
        var snapshot = fixture.snapshot
        snapshot.hosts = [localHost, remoteHost]
        let model = try makeModel(
            database: try WorkspaceDatabase.inMemory(),
            localHostID: localHost.id,
            snapshot: snapshot,
            kwtRemoteProvisioner: { _ in
                throw KwtRemoteInstallError.bundleIncomplete
            }
        )

        await #expect {
            try await model.loadWorktreeChanges(fixture.worktree)
        } throws: { error in
            (error as? any WorktreeChangesRetryClassifying)?.isRetryable
                == false
        }
        await model.shutdown()
    }

    @Test("transient provisioning failures remain retryable")
    @MainActor
    func transientProvisioningFailureIsRetryable() async throws {
        let fixture = makeFixture()
        let localHost = HostSummary.fixture()
        var remoteHost = fixture.snapshot.hosts[0]
        remoteHost.kind = .remote
        remoteHost.platform = .linux
        remoteHost.sshDestination = "user-a@builder.example.test"
        var snapshot = fixture.snapshot
        snapshot.hosts = [localHost, remoteHost]
        let model = try makeModel(
            database: try WorkspaceDatabase.inMemory(),
            localHostID: localHost.id,
            snapshot: snapshot,
            kwtRemoteProvisioner: { _ in
                throw KwtSSHLeaseError.acquisitionTimedOut
            }
        )

        await #expect {
            try await model.loadWorktreeChanges(fixture.worktree)
        } throws: { error in
            (error as? any WorktreeChangesRetryClassifying)?.isRetryable
                == true
        }
        await model.shutdown()
    }

    @Test("route resolution failures stop automatic retries")
    @MainActor
    func routeResolutionFailureIsNotRetryable() async throws {
        let fixture = makeFixture()
        let localHost = HostSummary.fixture()
        var remoteHost = fixture.snapshot.hosts[0]
        remoteHost.kind = .remote
        remoteHost.platform = .linux
        remoteHost.sshDestination = "user-a@builder.example.test"
        var snapshot = fixture.snapshot
        snapshot.hosts = [localHost, remoteHost]
        let model = try makeModel(
            database: try WorkspaceDatabase.inMemory(),
            localHostID: localHost.id,
            snapshot: snapshot,
            sshRouteIdentityResolver: { _ in
                throw KwtSSHRouteError.helperUnavailable
            }
        )

        await #expect {
            try await model.loadWorktreeChanges(fixture.worktree)
        } throws: { error in
            (error as? any WorktreeChangesRetryClassifying)?.isRetryable
                == false
        }
        await model.shutdown()
    }

    @MainActor
    @Test(
        "Windows refresh accepts equivalent paths and reads the original inventory spelling",
        arguments: [
            (#"C:\Worktrees\Topic"#, "c:/worktrees/topic"),
            (#"\\server\share\Topic"#, "//SERVER/share/topic"),
            ("//server/share", #"\\SERVER\Share"#),
            (#"\\wsl.localhost\Ubuntu\repo"#, "//WSL.LOCALHOST/ubuntu/repo"),
        ]
    )
    func windowsRefreshPreservesReadPath(path: String, requestedPath: String) async throws {
        let fixture = makeFixture()
        let localHost = HostSummary.fixture()
        var snapshot = fixture.snapshot
        snapshot.hosts[0].kind = .remote
        snapshot.hosts[0].platform = .windows
        snapshot.hosts[0].sshDestination = "user-a@builder.example.test"
        snapshot.hosts.append(localHost)
        snapshot.worktrees[0].path = path
        var requested = snapshot.worktrees[0]
        requested.path = requestedPath
        let paths = LockedValue<[String]>([])
        let model = try makeModel(
            database: try WorkspaceDatabase.inMemory(),
            localHostID: localHost.id,
            snapshot: snapshot,
            kwtWorktreeChangesReader: { path, repository, generation, _, _ in
                paths.withLock { $0.append(path) }
                return WorktreeFileChanges(
                    repository: repository, path: path, generation: generation,
                    state: .clean, summary: .clean, files: [], observedAt: "now"
                )
            }
        )
        let result = try await model.loadWorktreeChanges(requested)
        #expect(paths.load() == [path])
        #expect(result.path == path)
        await model.shutdown()
    }

    private func makeFixture() -> AuthorityFixture {
        let host = HostSummary.fixture()
        var project = ProjectSummary.fixture(hostID: host.id)
        project.scopedKey = "github.com/kenn-io/ghosthub"
        var worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id,
            path: "/repo/topic"
        )
        worktree.generation = "0123456789abcdef0123456789abcdef"
        return AuthorityFixture(
            snapshot: WorkspaceSnapshot.fixture(
                hosts: [host],
                projects: [project],
                worktrees: [worktree]
            ),
            project: project,
            worktree: worktree
        )
    }
}

private struct AuthorityFixture {
    let snapshot: WorkspaceSnapshot
    let project: ProjectSummary
    let worktree: WorktreeSummary
}

private struct ReadArguments {
    let path: String
    let repository: String
    let generation: String
    let host: CommandHost
}
