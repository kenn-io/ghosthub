import Foundation
import Testing
@testable import GhosthubWorkspace

struct WorkspaceKeyResolverTests {
    @Test("host and worktree keys use configured keys before uuid fallback")
    func keysUseConfiguredValuesBeforeUUIDFallback() {
        let localID = Self.uuid(1)
        let remoteID = Self.uuid(2)
        let projectID = Self.uuid(3)
        let configuredHost = HostSummary(
            id: localID,
            configKey: "local",
            name: "Local",
            kind: .selfHost,
            platform: .macOS
        )
        let fallbackHost = HostSummary(
            id: remoteID,
            name: "Remote",
            kind: .remote,
            platform: .linux
        )
        let configuredWorktree = WorktreeSummary(
            id: Self.uuid(4),
            hostID: localID,
            projectID: projectID,
            scopedKey: "worktree:/repo/app",
            name: "app",
            path: "/repo/app",
            branch: "main"
        )
        let fallbackWorktree = WorktreeSummary(
            id: Self.uuid(5),
            hostID: remoteID,
            projectID: projectID,
            name: "remote-app",
            path: "/srv/app",
            branch: "main"
        )

        #expect(
            WorkspaceKeyResolver.hostKey(for: configuredHost)
                == "local"
        )
        #expect(
            WorkspaceKeyResolver.hostKey(for: fallbackHost)
                == remoteID.uuidString
        )
        #expect(
            WorkspaceKeyResolver.worktreeKey(for: configuredWorktree)
                == "worktree:/repo/app"
        )
        #expect(
            WorkspaceKeyResolver.worktreeKey(for: fallbackWorktree)
                == fallbackWorktree.id.uuidString
        )
    }

    @Test("worktree path keys round-trip with legacy raw path fallback")
    func worktreePathKeysRoundTrip() {
        #expect(
            WorkspaceKeyResolver.worktreeKey(path: "/repo/app")
                == "worktree:/repo/app"
        )
        #expect(
            WorkspaceKeyResolver.worktreePath(
                fromKey: "worktree:/repo/app"
            ) == "/repo/app"
        )
        #expect(
            WorkspaceKeyResolver.worktreePath(
                fromKey: "/repo/app"
            ) == "/repo/app"
        )
    }

    @Test("worktree lookup uses host key to disambiguate duplicate keys")
    func worktreeLookupUsesHostKey() {
        let localHost = HostSummary(
            id: Self.uuid(10),
            configKey: "local",
            name: "Local",
            kind: .selfHost,
            platform: .macOS
        )
        let remoteHost = HostSummary(
            id: Self.uuid(11),
            configKey: "epyc",
            name: "EPYC",
            kind: .remote,
            platform: .linux
        )
        let localProjectID = Self.uuid(12)
        let remoteProjectID = Self.uuid(13)
        let localWorktree = WorktreeSummary(
            id: Self.uuid(14),
            hostID: localHost.id,
            projectID: localProjectID,
            scopedKey: "worktree:/repo/app",
            name: "app-local",
            path: "/repo/app",
            branch: "main"
        )
        let remoteWorktree = WorktreeSummary(
            id: Self.uuid(15),
            hostID: remoteHost.id,
            projectID: remoteProjectID,
            scopedKey: "worktree:/repo/app",
            name: "app-remote",
            path: "/srv/app",
            branch: "main"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [localHost, remoteHost],
            projects: [],
            worktrees: [localWorktree, remoteWorktree]
        )

        #expect(
            WorkspaceKeyResolver.worktree(
                matching: "worktree:/repo/app",
                hostKey: "epyc",
                in: snapshot
            )?.id == remoteWorktree.id
        )
        #expect(
            WorkspaceKeyResolver.worktree(
                matching: "worktree:/repo/app",
                hostKey: nil,
                in: snapshot
            )?.id == localWorktree.id
        )
        #expect(
            WorkspaceKeyResolver.worktree(
                matching: "worktree:/repo/app",
                hostKey: "missing-host",
                in: snapshot
            ) == nil
        )
    }

    @Test("project lookup uses registry id and optional host key")
    func projectLookupUsesRegistryIDAndHostKey() {
        let localHost = HostSummary(
            id: Self.uuid(20),
            configKey: "local",
            name: "Local",
            kind: .selfHost,
            platform: .macOS
        )
        let remoteHost = HostSummary(
            id: Self.uuid(21),
            configKey: "epyc",
            name: "EPYC",
            kind: .remote,
            platform: .linux
        )
        let localProject = ProjectSummary(
            id: Self.uuid(22),
            hostID: localHost.id,
            scopedKey: "repo:/repo/app",
            registryID: "prj_app",
            name: "app",
            rootPath: "/repo/app"
        )
        let remoteProject = ProjectSummary(
            id: Self.uuid(23),
            hostID: remoteHost.id,
            scopedKey: "fleet:epyc:repo:/srv/app",
            registryID: "prj_app",
            name: "app",
            rootPath: "/srv/app"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [localHost, remoteHost],
            projects: [localProject, remoteProject],
            worktrees: []
        )

        #expect(
            WorkspaceKeyResolver.project(
                registryID: "prj_app",
                hostKey: "epyc",
                in: snapshot
            )?.id == remoteProject.id
        )
        #expect(
            WorkspaceKeyResolver.project(
                registryID: "prj_app",
                hostKey: nil,
                in: snapshot
            )?.id == localProject.id
        )
    }

    private static func uuid(_ value: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, 0, 0, value
        ))
    }
}
