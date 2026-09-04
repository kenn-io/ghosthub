import Foundation
import GhosthubPersistence
import GhosthubTransport
import GhosthubTmux
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("worktree changes loader authority")
struct WorktreeChangesLoaderAuthorityTests {
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
