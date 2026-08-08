import GhosthubTransport
import Foundation
import Testing
@testable import GhosthubApp
import GhosthubTmux
import GhosthubWorkspace

@Suite("kwt inventory")
struct KwtInventoryClientTests {
    @Test("remote status 255 does not assume an SSH transport failure")
    func describesAmbiguousRemoteFailure() {
        let error = KwtInventoryError.commandFailed(
            host: "Build Host",
            status: 255
        )

        #expect(error.localizedDescription.contains("Remote kwt inventory"))
        #expect(error.localizedDescription.contains("Build Host"))
        #expect(error.localizedDescription.contains("exact SSH destination"))
    }

    @Test("projects and exact session names survive shell startup noise")
    func readsProjectsAndWorktrees() async throws {
        let client = KwtInventoryClient(
            localRunner: { _, command in
                #expect(command.hasPrefix("ghosthub_kwt_path='/Applications/Ghost Hub/kwt';"))
                if command.contains("projects --json") {
                    return (
                        0,
                        "zsh banner\nGHOSTHUB_KWT_JSON\n" +
                            #"[{"repository":"github.com/kenn-io/docbank","name":"docbank","path":"/code/docbank","last_touched":"2026-07-20T00:00:00Z"}]"#
                    )
                }
                if command.contains("workspace list --json") {
                    return (0, "GHOSTHUB_KWT_JSON\n[]")
                }
                return (
                    0,
                    "GHOSTHUB_KWT_JSON\n" +
                        #"[{"path":"/code/docbank","branch":"main","commit_hash":"abc","is_main":true,"repository":"github.com/kenn-io/docbank","session_name":"kwt-docbank-main","tmux_socket_name":"kwt-pr-0123456789abcdef"}]"#
                )
            },
            localBinaryPath: "/Applications/Ghost Hub/kwt",
            loginShellProvider: { "/bin/zsh" }
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.projects.map(\.project.name) == ["docbank"])
        #expect(
            inventory.projects[0].worktrees.map(\.sessionName)
                == ["kwt-docbank-main"]
        )
        #expect(
            inventory.projects[0].worktrees.map(\.tmuxSocketName)
                == ["kwt-pr-0123456789abcdef"]
        )
        #expect(inventory.projects[0].warning == nil)
    }

    @Test("registered directories are loaded independently of projects")
    func readsDirectoryWorkspaces() async throws {
        let client = KwtInventoryClient(
            localRunner: { _, command in
                if command.contains("workspace list --json") {
                    return (
                        0,
                        "GHOSTHUB_KWT_JSON\n" +
                            #"[{"name":"jibot","path":"/workspaces/jibot","session_name":"kwt-workspace-dir-jibot-abc","session_live":true}]"#
                    )
                }
                return (0, "GHOSTHUB_KWT_JSON\n[]")
            }
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.projects.isEmpty)
        #expect(inventory.directoryWorkspaces == [
            KwtDirectoryWorkspaceRecord(
                name: "jibot",
                path: "/workspaces/jibot",
                sessionName: "kwt-workspace-dir-jibot-abc",
                sessionLive: true
            ),
        ])
        #expect(inventory.directoryWorkspaceWarning == nil)
    }

    @Test("directory inventory failure does not hide repository projects")
    func directoryFailureIsPartial() async throws {
        let client = KwtInventoryClient(
            localRunner: { _, command in
                if command.contains("workspace list --json") {
                    return (42, "")
                }
                if command.contains("projects --json") {
                    return (
                        0,
                        "GHOSTHUB_KWT_JSON\n" +
                            #"[{"repository":"repo","name":"repo","path":"/repo"}]"#
                    )
                }
                return (0, "GHOSTHUB_KWT_JSON\n[]")
            }
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.projects.map(\.project.name) == ["repo"])
        #expect(inventory.directoryWorkspaces.isEmpty)
        #expect(inventory.directoryWorkspaceWarning != nil)
    }

    @Test("project inventory failure does not hide registered directories")
    func projectFailureIsPartial() async throws {
        let client = KwtInventoryClient(
            localRunner: { _, command in
                if command.contains("projects --json") {
                    return (42, "")
                }
                if command.contains("workspace list --json") {
                    return (
                        0,
                        "GHOSTHUB_KWT_JSON\n" +
                            #"[{"name":"jibot","path":"/workspaces/jibot","session_name":"kwt-workspace-dir-jibot-abc","session_live":true}]"#
                    )
                }
                return (0, "GHOSTHUB_KWT_JSON\n[]")
            }
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.projects.isEmpty)
        #expect(inventory.projectsWarning != nil)
        #expect(inventory.directoryWorkspaces.map(\.name) == ["jibot"])
        #expect(inventory.directoryWorkspaceWarning == nil)
    }

    @Test("complete inventory failure remains fatal")
    func completeFailureThrows() async {
        let client = KwtInventoryClient(
            localRunner: { _, _ in (127, "") }
        )

        await #expect(throws: KwtInventoryError.commandFailed(
            host: "this Mac",
            status: 127
        )) {
            try await client.load(from: .local)
        }
    }

    @Test("remote inventory resolves kwt on the remote host")
    func remoteInventoryDoesNotUseBundledPath() async throws {
        let ssh = SSHHostInfo(user: "wesm", hostname: "builder", port: nil)
        let revision = String(repeating: "a", count: 40)
        let client = KwtInventoryClient(
            remoteRunner: { host, command in
                #expect(host == ssh)
                #expect(command.hasPrefix(
                    "ghosthub_kwt_path=\"$HOME/.ghosthub/helpers/kwt/"
                        + "\(revision)/kwt\";"
                ))
                #expect(!command.contains("/Applications/Ghosthub.app"))
                if command.contains("workspace list --json") {
                    return (
                        0,
                        "GHOSTHUB_KWT_JSON\n" +
                            #"[{"name":"hub","path":"/srv/hub","session_name":"kwt-workspace-dir-hub-abc","session_live":false}]"#
                    )
                }
                return (0, "GHOSTHUB_KWT_JSON\n[]")
            },
            localBinaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt",
            remoteBinaryRevision: revision
        )

        let inventory = try await client.load(from: .ssh(ssh))

        #expect(inventory.projects.isEmpty)
        #expect(inventory.directoryWorkspaces.map(\.path) == ["/srv/hub"])
    }

    @Test("Windows inventory invokes native kwt through PowerShell")
    func windowsRemoteInventory() async throws {
        let revision = String(repeating: "b", count: 40)
        let managedPath = try #require(
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: revision
            )
        )
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let client = KwtInventoryClient(
            remoteRunner: { host, command in
                #expect(host == ssh)
                #expect(command.contains(
                    powerShellEncodedArgument(managedPath)
                ))
                #expect(!command.contains("Get-Command kwt.exe"))
                let expectedArguments = command.contains(
                    powerShellEncodedArgument("workspace")
                ) ? ["workspace", "list", "--json"] : ["projects", "--json"]
                #expect(command.contains(
                    expectedArguments
                        .map(powerShellEncodedArgument)
                        .joined(separator: " ")
                ))
                #expect(command.contains(
                    "Write-Output "
                        + powerShellEncodedArgument("GHOSTHUB_KWT_JSON")
                ))
                #expect(!command.contains("command -v"))
                let json = expectedArguments.first == "workspace"
                    ? #"[{"name":"hub","path":"C:\\hub","session_name":"kwt-workspace-dir-hub-abc","session_live":false}]"#
                    : "[]"
                return (
                    0,
                    "PowerShell banner without newline"
                        + "GHOSTHUB_KWT_JSON\r\n\(json)\r\n"
                )
            },
            remoteBinaryRevision: revision
        )

        let inventory = try await client.load(from: .ssh(ssh))

        #expect(inventory.projects.isEmpty)
        #expect(inventory.directoryWorkspaces.map(\.name) == ["hub"])
    }

    @Test("real zsh login shell loads the current kwt inventory")
    func loadsCurrentInventoryThroughZsh() async throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_LIVE_INTEGRATION_TESTS"
        ] == "1" else { return }
        let availability = AccountCommandRunner.runLoginShell(
            shell: "/bin/zsh",
            command: "command -v kwt >/dev/null",
            timeout: 5
        )
        guard availability.status == 0 else { return }

        let inventory = try await KwtInventoryClient(
            processTimeout: 15,
            loginShellProvider: { "/bin/zsh" }
        ).load(from: .local)

        #expect(!inventory.projects.isEmpty)
        #expect(inventory.projects.allSatisfy { $0.warning == nil })
    }

    @Test("one unreadable project does not hide other registered projects")
    func retainsProjectsWhenWorktreeListingFails() async throws {
        let client = KwtInventoryClient(
            localRunner: { _, command in
                if command.contains("projects --json") {
                    return (
                        0,
                        "GHOSTHUB_KWT_JSON\n" +
                            #"[{"repository":"one","name":"one","path":"/one"},{"repository":"two","name":"two","path":"/two"}]"#
                    )
                }
                if command.contains("/one") {
                    return (42, "")
                }
                return (0, "GHOSTHUB_KWT_JSON\n[]")
            }
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.projects.map(\.project.name) == ["one", "two"])
        #expect(inventory.projects[0].warning != nil)
        #expect(inventory.projects[1].warning == nil)
    }

    @Test("kwt replaces transitional host inventory and preserves stable ids")
    func mergesAuthoritativeHostInventory() {
        let hostID = UUID()
        let oldProjectID = UUID()
        let oldWorktreeID = UUID()
        let host = HostSummary(
            id: hostID,
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS
        )
        let existingProject = ProjectSummary(
            id: oldProjectID,
            hostID: hostID,
            scopedKey: "legacy",
            registryID: "prj_legacy",
            name: "Old name",
            rootPath: "/code/docbank"
        )
        let existingWorktree = WorktreeSummary(
            id: oldWorktreeID,
            hostID: hostID,
            projectID: oldProjectID,
            registryID: "wtr_legacy",
            name: "main",
            path: "/code/docbank",
            branch: "main"
        )
        let staleProject = ProjectSummary(
            id: UUID(),
            hostID: hostID,
            name: "external-agent",
            rootPath: "/code/removed"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [existingProject, staleProject],
            worktrees: [existingWorktree]
        )
        let inventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "github.com/kenn-io/docbank",
                    name: "docbank",
                    path: "/code/docbank",
                    lastTouched: nil
                ),
                worktrees: [
                    KwtWorktreeRecord(
                        path: "/code/docbank",
                        branch: "main",
                        commitHash: "abc",
                        isMain: true,
                        createdAt: "2026-07-29T19:00:00Z",
                        generation: "0123456789abcdef0123456789abcdef",
                        repository: "github.com/kenn-io/docbank",
                        sessionName: "kwt-docbank-main"
                    ),
                ],
                warning: nil
            ),
        ])

        let merged = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: snapshot
        )

        #expect(merged.projects.map(\.name) == ["docbank"])
        #expect(merged.projects[0].id == oldProjectID)
        #expect(merged.projects[0].registryID == nil)
        #expect(merged.worktrees[0].id == oldWorktreeID)
        #expect(merged.worktrees[0].registryID == nil)
        #expect(
            merged.worktrees[0].createdAt
                == "2026-07-29T19:00:00Z"
        )
        #expect(
            merged.worktrees[0].generation
                == "0123456789abcdef0123456789abcdef"
        )
        #expect(merged.worktrees[0].tmuxSessionName == "kwt-docbank-main")
        #expect(merged.worktrees[0].sessionBackend == .localTmux)
    }

    @Test("a refresh without a socket cannot unprotect a workspace")
    func retainsProtectedSocketWhenRefreshOmitsIt() {
        let hostID = UUID()
        let projectID = UUID()
        let worktreeID = UUID()
        let snapshot = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: hostID,
                name: "This Mac",
                kind: .selfHost,
                platform: .macOS
            )],
            projects: [ProjectSummary(
                id: projectID,
                hostID: hostID,
                scopedKey: "repo",
                name: "repo",
                rootPath: "/repo"
            )],
            worktrees: [WorktreeSummary(
                id: worktreeID,
                hostID: hostID,
                projectID: projectID,
                scopedKey: "/repo-pr-32",
                name: "pr-32",
                path: "/repo-pr-32",
                branch: "contributor/pr-32",
                tmuxSessionName: "kwt-repo-pr-32",
                tmuxSocketName: "kwt-pr-0123456789abcdef"
            )]
        )
        let inventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "repo",
                    name: "repo",
                    path: "/repo",
                    lastTouched: nil
                ),
                worktrees: [KwtWorktreeRecord(
                    path: "/repo-pr-32",
                    branch: "contributor/pr-32",
                    commitHash: "abc",
                    isMain: false,
                    createdAt: nil,
                    repository: "repo",
                    sessionName: "kwt-repo-pr-32",
                    tmuxSocketName: nil
                )],
                warning: nil
            ),
        ])

        let merged = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: snapshot
        )

        #expect(merged.worktrees.count == 1)
        #expect(
            merged.worktrees[0].tmuxSocketName == "kwt-pr-0123456789abcdef"
        )
    }

    @Test("a failed project listing preserves its last successful worktrees")
    func preservesProjectWorktreesAcrossTransientFailure() {
        let hostID = UUID()
        let projectID = UUID()
        let worktreeID = UUID()
        let snapshot = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: hostID,
                name: "This Mac",
                kind: .selfHost,
                platform: .macOS
            )],
            projects: [ProjectSummary(
                id: projectID,
                hostID: hostID,
                scopedKey: "repo",
                name: "repo",
                rootPath: "/repo"
            )],
            worktrees: [WorktreeSummary(
                id: worktreeID,
                hostID: hostID,
                projectID: projectID,
                scopedKey: "/repo",
                name: "main",
                path: "/repo",
                branch: "main",
                tmuxSessionName: "kwt-repo-main"
            )]
        )
        let inventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "repo",
                    name: "repo",
                    path: "/repo",
                    lastTouched: nil
                ),
                worktrees: [],
                warning: "temporary kwt failure"
            ),
        ])

        let merged = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: snapshot
        )

        #expect(merged.worktrees.map(\.id) == [worktreeID])
        #expect(merged.worktrees[0].tmuxSessionName == "kwt-repo-main")
    }

    @Test("failed project refresh retains its cached kwt records")
    func retainsCachedRecordsBeforeStoredOverlay() {
        let project = KwtProjectRecord(
            repository: "repo",
            name: "repo",
            path: "/repo",
            lastTouched: nil
        )
        let worktree = KwtWorktreeRecord(
            path: "/repo",
            branch: "main",
            commitHash: "abc",
            isMain: true,
            createdAt: nil,
            repository: "repo",
            sessionName: "kwt-repo-main"
        )
        let previous = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [worktree],
                warning: nil
            ),
        ])
        let failed = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [],
                warning: "temporary failure"
            ),
        ])

        let retained = failed.retainingFailedProjectWorktrees(from: previous)

        #expect(retained.projects[0].worktrees == [worktree])
        #expect(retained.projects[0].warning == "temporary failure")
    }

    @Test("failed project list refresh retains cached projects")
    func retainsCachedProjectsWhenProjectListFails() {
        let project = KwtProjectRecord(
            repository: "repo",
            name: "repo",
            path: "/repo",
            lastTouched: nil
        )
        let previous = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [],
                warning: nil
            ),
        ])
        let failed = KwtHostInventory(
            projects: [],
            projectsWarning: "temporary failure"
        )

        let retained = failed.retainingFailedProjectWorktrees(from: previous)

        #expect(retained.projects.map(\.project) == [project])
        #expect(retained.projectsWarning == "temporary failure")
    }

    @Test("failed initial project list preserves persisted project rows")
    func failedProjectListPreservesStoredOverlay() {
        let hostID = UUID()
        let projectID = UUID()
        let worktreeID = UUID()
        let snapshot = WorkspaceSnapshot(
            hosts: [.init(
                id: hostID,
                name: "This Mac",
                kind: .selfHost,
                platform: .macOS
            )],
            projects: [.init(
                id: projectID,
                hostID: hostID,
                scopedKey: "repo",
                name: "repo",
                rootPath: "/repo"
            )],
            worktrees: [.init(
                id: worktreeID,
                hostID: hostID,
                projectID: projectID,
                scopedKey: "/repo",
                name: "main",
                path: "/repo",
                branch: "main"
            )]
        )
        let inventory = KwtHostInventory(
            projects: [],
            projectsWarning: "temporary failure",
            directoryWorkspaces: [.init(
                name: "jibot",
                path: "/workspaces/jibot",
                sessionName: "kwt-workspace-dir-jibot-abc",
                sessionLive: true
            )]
        )

        let merged = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: snapshot
        )

        #expect(merged.projects.map(\.id) == [projectID])
        #expect(merged.worktrees.map(\.id) == [worktreeID])
        #expect(merged.directoryWorkspaces.map(\.name) == ["jibot"])
    }

    @Test("failed directory refresh retains its cached records")
    func retainsCachedDirectoryWorkspaces() {
        let workspace = KwtDirectoryWorkspaceRecord(
            name: "jibot",
            path: "/workspaces/jibot",
            sessionName: "kwt-workspace-dir-jibot-abc",
            sessionLive: true
        )
        let previous = KwtHostInventory(
            projects: [],
            directoryWorkspaces: [workspace]
        )
        let failed = KwtHostInventory(
            projects: [],
            directoryWorkspaceWarning: "temporary failure"
        )

        let retained = failed.retainingFailedProjectWorktrees(from: previous)

        #expect(retained.directoryWorkspaces == [workspace])
        #expect(retained.directoryWorkspaceWarning == "temporary failure")
    }

    @Test("directory records merge with stable host-path identity")
    func mergesDirectoryWorkspaces() {
        let hostID = UUID()
        let existingID = UUID()
        let snapshot = WorkspaceSnapshot(
            hosts: [.init(
                id: hostID,
                name: "This Mac",
                kind: .selfHost,
                platform: .macOS
            )],
            projects: [],
            worktrees: [],
            directoryWorkspaces: [.init(
                id: existingID,
                hostID: hostID,
                name: "old-name",
                path: "/workspaces/jibot",
                tmuxSessionName: "old-session",
                sessionLive: false
            )]
        )
        let inventory = KwtHostInventory(
            projects: [],
            directoryWorkspaces: [.init(
                name: "jibot",
                path: "/workspaces/jibot",
                sessionName: "kwt-workspace-dir-old-name-abc",
                sessionLive: true
            )]
        )

        let merged = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: snapshot
        )

        #expect(merged.directoryWorkspaces.count == 1)
        #expect(merged.directoryWorkspaces[0].id == existingID)
        #expect(merged.directoryWorkspaces[0].name == "jibot")
        #expect(
            merged.directoryWorkspaces[0].tmuxSessionName
                == "kwt-workspace-dir-old-name-abc"
        )
        #expect(merged.directoryWorkspaces[0].sessionLive)
    }

    @Test("failed project retention excludes a worktree already removed")
    func failedProjectDoesNotRestoreRemovedWorktree() {
        let project = KwtProjectRecord(
            repository: "repo",
            name: "repo",
            path: "/repo",
            lastTouched: nil
        )
        let removed = KwtWorktreeRecord(
            path: "/worktrees/removed",
            branch: "removed",
            commitHash: "abc",
            isMain: false,
            createdAt: nil,
            generation: "removed-generation",
            repository: "repo",
            sessionName: "kwt-repo-removed"
        )
        let previous = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [removed],
                warning: nil
            ),
        ])
        let failed = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [],
                warning: "temporary failure"
            ),
        ])

        let retained = failed.retainingFailedProjectWorktrees(
            from: previous,
            excludingWorktrees: [
                KwtWorktreeIdentity(
                    path: removed.path,
                    generation: "removed-generation"
                ),
            ]
        )

        #expect(retained.projects[0].worktrees.isEmpty)
    }

    @Test("failed project retention keeps a replacement generation")
    func failedProjectKeepsReplacementGeneration() {
        let project = KwtProjectRecord(
            repository: "repo",
            name: "repo",
            path: "/repo",
            lastTouched: nil
        )
        let replacement = KwtWorktreeRecord(
            path: "/worktrees/reused",
            branch: "replacement",
            commitHash: "def",
            isMain: false,
            createdAt: nil,
            generation: "replacement-generation",
            repository: "repo",
            sessionName: "kwt-repo-replacement"
        )
        let previous = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [replacement],
                warning: nil
            ),
        ])
        let failed = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [],
                warning: "temporary failure"
            ),
        ])

        let retained = failed.retainingFailedProjectWorktrees(
            from: previous,
            excludingWorktrees: [
                KwtWorktreeIdentity(
                    path: replacement.path,
                    generation: "removed-generation"
                ),
            ]
        )

        #expect(retained.projects[0].worktrees == [replacement])
    }

    @Test("warning inventory records merge over a fresh snapshot")
    func warningRecordsMergeOverFreshSnapshot() {
        let hostID = UUID()
        let project = KwtProjectRecord(
            repository: "repo",
            name: "repo",
            path: "/repo",
            lastTouched: nil
        )
        let worktree = KwtWorktreeRecord(
            path: "/repo-feature",
            branch: "feature",
            commitHash: "abc",
            isMain: false,
            createdAt: nil,
            repository: "repo",
            sessionName: "kwt-repo-feature"
        )
        let inventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [worktree],
                warning: "refresh failed after cached records were retained"
            ),
        ])
        let fresh = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: hostID,
                name: "This Mac",
                kind: .selfHost,
                platform: .macOS
            )],
            projects: [],
            worktrees: []
        )

        let merged = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: fresh
        )

        #expect(merged.projects.map(\.name) == ["repo"])
        #expect(merged.worktrees.map(\.branch) == ["feature"])
        #expect(merged.worktrees[0].tmuxSessionName == "kwt-repo-feature")
    }

    @Test("successful host inventory overlays a later stored snapshot")
    func successfulInventorySurvivesStoredRefresh() {
        let hostID = UUID()
        let storedSession = TmuxSessionSummary(
            name: "stale-stored-session",
            managed: false,
            windows: []
        )
        let discoveredSession = TmuxSessionSummary(
            name: "docbank",
            managed: false,
            windows: []
        )
        let storedSnapshot = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: hostID,
                name: "build-box",
                kind: .remote,
                platform: .linux,
                tmuxSessions: [storedSession]
            )],
            projects: [],
            worktrees: []
        )

        let overlaid = HostInventoryOverlay.apply(
            kwtInventoriesByHost: [:],
            tmuxSessionsByHost: [hostID: [discoveredSession]],
            to: storedSnapshot
        )

        #expect(overlaid.hosts[0].tmuxSessions == [discoveredSession])
    }

    @Test("Herdr inventory overlays only Herdr sessions")
    func herdrInventoryIsAdditive() {
        let hostID = UUID()
        let tmux = TmuxSessionSummary(
            name: "tmux-kept",
            managed: false,
            windows: []
        )
        let diagnostic = RemoteHostDiagnostic.missingKwtCapability
        let stored = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: hostID,
                name: "build-box",
                kind: .remote,
                platform: .linux,
                lastKnownReachable: true,
                remoteDiagnostics: [diagnostic],
                tmuxSessions: [tmux]
            )],
            projects: [],
            worktrees: []
        )
        let herdr = HerdrSessionSummary(name: "api", isDefault: true, state: .running)

        let overlaid = HostInventoryOverlay.apply(
            kwtInventoriesByHost: [:],
            tmuxSessionsByHost: [:],
            herdrSessionsByHost: [hostID: [herdr]],
            herdrAvailabilityByHost: [hostID: true],
            to: stored
        )

        #expect(overlaid.hosts[0].herdrSessions == [herdr])
        #expect(overlaid.hosts[0].herdrAvailable)
        #expect(overlaid.hosts[0].tmuxSessions == [tmux])
        #expect(overlaid.hosts[0].lastKnownReachable)
        #expect(overlaid.hosts[0].remoteDiagnostics == [diagnostic])
    }
}
