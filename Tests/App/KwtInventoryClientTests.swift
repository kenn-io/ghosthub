import GhosthubTransport
import Foundation
import Testing
@testable import GhosthubApp
import GhosthubTmux
import GhosthubWorkspace

@Suite("kwt inventory")
struct KwtInventoryClientTests {
    @Test("snapshot reconciliation normalizes paths linearly")
    func snapshotReconciliationNormalizesPathsLinearly() {
        let hostID = UUID()
        let count = 200
        let projects = (0 ..< count).map { index in
            ProjectSummary(
                id: UUID(),
                hostID: hostID,
                scopedKey: "repo-\(index)",
                name: "repo-\(index)",
                rootPath: "/code/repo-\(index)"
            )
        }
        let worktrees = projects.enumerated().map { index, project in
            WorktreeSummary(
                id: UUID(),
                hostID: hostID,
                projectID: project.id,
                scopedKey: "/code/repo-\(index)",
                name: "main",
                path: "/code/repo-\(index)",
                branch: "main",
                isPrimary: true,
                tmuxSessionName: "repo-\(index)"
            )
        }
        let inventory = KwtHostInventory(projects: projects.enumerated().map {
            index, _ in
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "repo-\(index)",
                    name: "repo-\(index)",
                    path: "/code/repo-\(index)",
                    lastTouched: nil
                ),
                worktrees: [KwtWorktreeRecord(
                    path: "/code/repo-\(index)",
                    branch: "main",
                    commitHash: "abc",
                    isMain: true,
                    createdAt: nil,
                    generation: nil,
                    repository: "repo-\(index)",
                    sessionName: "repo-\(index)"
                )],
                warning: nil
            )
        })
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: projects,
            worktrees: worktrees
        )
        var normalizationCount = 0

        _ = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: snapshot,
            normalizePath: { path in
                normalizationCount += 1
                return path
            }
        )

        #expect(normalizationCount <= count * 4)
    }

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

    @Test("remote inventory requires reviewed lease arguments")
    func remoteInventoryRequiresLease() async {
        let host = SSHHostInfo(
            user: "tester",
            hostname: "builder.example.test",
            port: nil
        )

        await #expect(throws: KwtInventoryError.sshLeaseRequired(
            host: "tester@builder.example.test"
        )) {
            try await KwtInventoryClient().load(from: .ssh(host))
        }
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
                            #"[{"repository":"github.com/kenn-io/docbank","name":"docbank","path":"/code/docbank","last_touched":"2026-07-20T00:00:00Z","registration_fingerprint":"opaque-observation"}]"#
                    )
                }
                if command.contains("workspace list --json") {
                    return (0, "GHOSTHUB_KWT_JSON\n[]")
                }
                return (
                    0,
                    "GHOSTHUB_KWT_JSON\n" +
                        #"[{"path":"/code/docbank","branch":"main","commit_hash":"abc","is_main":true,"repository":"github.com/kenn-io/docbank","session_name":"kwt-docbank-main","tmux_socket_name":"kwt-pr-0123456789abcdef","tmux_attach_mode":"protected"}]"#
                )
            },
            localBinaryPath: "/Applications/Ghost Hub/kwt",
            loginShellProvider: { "/bin/zsh" }
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.projects.map(\.project.name) == ["docbank"])
        #expect(
            inventory.projects[0].project.registrationFingerprint
                == "opaque-observation"
        )
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

    @Test(
        "project inventory requires a nonempty registration fingerprint",
        arguments: [
            #"{"repository":"repo","name":"repo","path":"/repo"}"#,
            #"{"repository":"repo","name":"repo","path":"/repo","registration_fingerprint":""}"#,
        ]
    )
    func rejectsMissingRegistrationFingerprint(record: String) async throws {
        let client = KwtInventoryClient(
            localRunner: { _, command in
                if command.contains("projects --json") {
                    return (0, "GHOSTHUB_KWT_JSON\n[\(record)]")
                }
                return (0, "GHOSTHUB_KWT_JSON\n[]")
            }
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.projects.isEmpty)
        #expect(inventory.projectsWarning != nil)
    }

    @Test("project records preserve trailing path whitespace")
    func projectRecordPreservesTrailingWhitespace() throws {
        let record = try JSONDecoder().decode(
            KwtProjectRecord.self,
            from: Data(
                #"{"repository":"repo","name":"repo","path":"/repo ","registration_fingerprint":"opaque"}"#
                    .utf8
            )
        )

        #expect(record.path == "/repo ")
    }

    @Test("registered directories are loaded independently of projects")
    func readsDirectoryWorkspaces() async throws {
        let client = KwtInventoryClient(
            localRunner: { _, command in
                if command.contains("workspace list --json") {
                    return (
                        0,
                        "GHOSTHUB_KWT_JSON\n" +
                            #"[{"name":"jibot","path":"/workspaces/jibot","session_name":"kwt-workspace-dir-jibot-abc","session_live":true,"tmux_socket_name":"kwt","tmux_attach_mode":"direct"}]"#
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
                sessionLive: true,
                tmuxSocketName: "kwt",
                tmuxAttachMode: .direct
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
                            #"[{"repository":"repo","name":"repo","path":"/repo","registration_fingerprint":"repo-fingerprint"}]"#
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

    @Test("retryable directory inventory failure recovers")
    func retryableDirectoryFailureRecovers() async throws {
        let directoryRuns = LockedValue(0)
        let client = KwtInventoryClient(
            localRunner: { _, command in
                guard command.contains("workspace list --json") else {
                    return (0, "GHOSTHUB_KWT_JSON\n[]")
                }
                var run = 0
                directoryRuns.withLock { runs in
                    runs += 1
                    run = runs
                }
                if run == 1 {
                    return (
                        1,
                        "GHOSTHUB_KWT_JSON\n" +
                            #"{"error":{"code":"inventory_timeout","message":"inventory refresh timed out","retryable":true}}"#
                    )
                }
                return (
                    0,
                    "GHOSTHUB_KWT_JSON\n" +
                        #"[{"name":"hub","path":"/workspaces/hub","session_name":"kwt-workspace-dir-hub-abc","session_live":true,"tmux_socket_name":"kwt","tmux_attach_mode":"direct"}]"#
                )
            },
            retryDelays: [.zero]
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.directoryWorkspaces.map(\.path) == ["/workspaces/hub"])
        #expect(inventory.directoryWorkspaceWarning == nil)
        #expect(directoryRuns.load() == 2)
    }

    @Test("nonretryable directory inventory failure is not repeated")
    func nonretryableDirectoryFailureIsNotRepeated() async throws {
        let directoryRuns = LockedValue(0)
        let client = KwtInventoryClient(
            localRunner: { _, command in
                guard command.contains("workspace list --json") else {
                    return (0, "GHOSTHUB_KWT_JSON\n[]")
                }
                directoryRuns.withLock { $0 += 1 }
                return (
                    1,
                    "GHOSTHUB_KWT_JSON\n" +
                        #"{"error":{"code":"invalid_request","message":"invalid inventory request","retryable":false}}"#
                )
            },
            retryDelays: [.zero]
        )

        let inventory = try await client.load(from: .local)

        #expect(inventory.directoryWorkspaces.isEmpty)
        #expect(inventory.directoryWorkspaceWarning != nil)
        #expect(directoryRuns.load() == 1)
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
                            #"[{"name":"jibot","path":"/workspaces/jibot","session_name":"kwt-workspace-dir-jibot-abc","session_live":true,"tmux_socket_name":"kwt","tmux_attach_mode":"direct"}]"#
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
        let ssh = SSHHostInfo(user: "tester", hostname: "builder", port: nil)
        let revision = String(repeating: "a", count: 40)
        let client = KwtInventoryClient(
            remoteRunner: { host, arguments, command in
                #expect(host == ssh)
                #expect(arguments == ["-F", "/dev/null", "-S", "/tmp/kwt.sock"])
                #expect(command.hasPrefix(
                    "ghosthub_kwt_path=\"$HOME/.ghosthub/helpers/kwt/"
                        + "\(revision)/kwt\";"
                ))
                #expect(!command.contains("/Applications/Ghosthub.app"))
                if command.contains("workspace list --json") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_KWT_JSON\n" +
                            #"[{"name":"hub","path":"/srv/hub","session_name":"kwt-workspace-dir-hub-abc","session_live":false,"tmux_socket_name":"kwt","tmux_attach_mode":"direct"}]"#,
                        stderr: ""
                    )
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_KWT_JSON\n[]",
                    stderr: ""
                )
            },
            localBinaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt",
            remoteBinaryRevision: revision
        )

        let inventory = try await client.load(
            from: .ssh(ssh),
            sshConnectionArguments: [
                "-F", "/dev/null", "-S", "/tmp/kwt.sock",
            ]
        )

        #expect(inventory.projects.isEmpty)
        #expect(inventory.directoryWorkspaces.map(\.path) == ["/srv/hub"])
    }

    @Test("remote project inventory is serialized")
    func remoteProjectInventoryIsSerialized() async throws {
        let ssh = SSHHostInfo(user: "tester", hostname: "builder", port: nil)
        let concurrency = LockedValue((active: 0, maximum: 0))
        let overlap = DispatchSemaphore(value: 0)
        let client = KwtInventoryClient(
            remoteRunner: { _, _, command in
                if command.contains("projects --json") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_KWT_JSON\n" +
                            #"[{"repository":"one","name":"one","path":"/one","registration_fingerprint":"one-fingerprint"},{"repository":"two","name":"two","path":"/two","registration_fingerprint":"two-fingerprint"}]"#,
                        stderr: ""
                    )
                }
                if command.contains("workspace list --json") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_KWT_JSON\n[]",
                        stderr: ""
                    )
                }

                var active = 0
                concurrency.withLock { state in
                    state.active += 1
                    state.maximum = max(state.maximum, state.active)
                    active = state.active
                }
                if active == 1 {
                    _ = overlap.wait(timeout: .now() + 0.2)
                } else {
                    overlap.signal()
                }
                concurrency.withLock { $0.active -= 1 }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_KWT_JSON\n[]",
                    stderr: ""
                )
            }
        )

        let inventory = try await client.load(
            from: .ssh(ssh),
            sshConnectionArguments: ["-S", "/tmp/kwt.sock"]
        )

        #expect(inventory.projects.count == 2)
        #expect(inventory.projects.allSatisfy { $0.warning == nil })
        #expect(concurrency.load().maximum == 1)
    }

    @Test("cancelled remote inventory stops before the next project")
    func cancelledRemoteInventoryStopsBeforeNextProject() async {
        let ssh = SSHHostInfo(user: "tester", hostname: "builder", port: nil)
        let projectRuns = LockedValue(0)
        let firstProjectStarted = DispatchSemaphore(value: 0)
        let firstProjectMayFinish = DispatchSemaphore(value: 0)
        let client = KwtInventoryClient(
            remoteRunner: { _, _, command in
                if command.contains("projects --json") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_KWT_JSON\n" +
                            #"[{"repository":"one","name":"one","path":"/one","registration_fingerprint":"one-fingerprint"},{"repository":"two","name":"two","path":"/two","registration_fingerprint":"two-fingerprint"},{"repository":"three","name":"three","path":"/three","registration_fingerprint":"three-fingerprint"}]"#,
                        stderr: ""
                    )
                }
                if command.contains("workspace list --json") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_KWT_JSON\n[]",
                        stderr: ""
                    )
                }

                var run = 0
                projectRuns.withLock { count in
                    count += 1
                    run = count
                }
                if run == 1 {
                    firstProjectStarted.signal()
                    _ = firstProjectMayFinish.wait(timeout: .now() + 1)
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_KWT_JSON\n[]",
                    stderr: ""
                )
            }
        )
        let load = Task<KwtHostInventory, Error> {
            try await client.load(
                from: CommandHost.ssh(ssh),
                sshConnectionArguments: ["-S", "/tmp/kwt.sock"]
            )
        }

        let didStart = await BlockingTask.run {
            firstProjectStarted.wait(timeout: .now() + 1) == .success
        }
        #expect(didStart)
        load.cancel()
        firstProjectMayFinish.signal()

        await #expect(throws: CancellationError.self) {
            try await load.value
        }
        #expect(projectRuns.load() == 1)
    }

    @Test("remote inventory loads sharing a route do not overlap")
    func sharedRouteRemoteInventoryIsSerialized() async throws {
        let ssh = SSHHostInfo(user: "tester", hostname: "builder", port: nil)
        let commandRuns = LockedValue(0)
        let activeCommands = LockedValue((active: 0, maximum: 0))
        let firstCommandStarted = DispatchSemaphore(value: 0)
        let firstCommandMayFinish = DispatchSemaphore(value: 0)
        let laterCommandStarted = DispatchSemaphore(value: 0)
        let client = KwtInventoryClient(
            remoteRunner: { _, _, _ in
                var run = 0
                commandRuns.withLock { count in
                    count += 1
                    run = count
                }
                activeCommands.withLock { state in
                    state.active += 1
                    state.maximum = max(state.maximum, state.active)
                }
                if run == 1 {
                    firstCommandStarted.signal()
                    _ = firstCommandMayFinish.wait(timeout: .now() + 1)
                } else {
                    laterCommandStarted.signal()
                }
                activeCommands.withLock { $0.active -= 1 }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_KWT_JSON\n[]",
                    stderr: ""
                )
            }
        )
        let lease = KwtSSHCommandLease { _ in
            KwtSSHConnection(
                arguments: ["-S", "/tmp/kwt.sock"],
                routeIdentity: "serialized-route",
                generation: 1
            )
        }
        let service = KwtInventoryService(client: client, lease: lease)
        let firstLoad = Task<KwtHostInventory, Error> {
            try await service.load(from: .ssh(ssh))
        }

        let didStartFirst = await BlockingTask.run {
            firstCommandStarted.wait(timeout: .now() + 1) == .success
        }
        #expect(didStartFirst)
        firstLoad.cancel()
        let secondLoad = Task<KwtHostInventory, Error> {
            try await service.load(from: .ssh(ssh))
        }
        let secondStartedBeforeFirstFinished = await BlockingTask.run {
            laterCommandStarted.wait(timeout: .now() + 0.2) == .success
        }
        #expect(!secondStartedBeforeFirstFinished)

        firstCommandMayFinish.signal()
        await #expect(throws: CancellationError.self) {
            try await firstLoad.value
        }
        let inventory = try await secondLoad.value

        #expect(inventory.projects.isEmpty)
        #expect(activeCommands.load().maximum == 1)
    }

    @Test("queued remote inventory reacquires after invalidation")
    func queuedRemoteInventoryReacquiresAfterInvalidation() async throws {
        let ssh = SSHHostInfo(user: "tester", hostname: "builder", port: nil)
        let route = KwtSSHRouteSnapshot.fixture(
            routeIdentity: "serialized-route"
        )
        let leaseGenerations = LockedValue(0)
        let leaseBorrows = LockedValue(0)
        let firstGenerationRuns = LockedValue(0)
        let firstCommandStarted = DispatchSemaphore(value: 0)
        let firstCommandMayFinish = DispatchSemaphore(value: 0)
        let laterBorrowStarted = DispatchSemaphore(value: 0)
        let pool = KwtSSHConnectionPool { route, _ in
            var generation = 0
            leaseGenerations.withLock {
                $0 += 1
                generation = $0
            }
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: UInt64(generation),
                arguments: ["generation=\(generation)"]
            )
        }
        let lease = KwtSSHCommandLease { _ in
            var borrow = 0
            leaseBorrows.withLock {
                $0 += 1
                borrow = $0
            }
            if borrow > 1 {
                laterBorrowStarted.signal()
            }
            return try await pool.acquire(route: route, prompt: { _ in "" })
        }
        let client = KwtInventoryClient(
            remoteRunner: { _, arguments, _ in
                if arguments == ["generation=1"] {
                    var run = 0
                    firstGenerationRuns.withLock {
                        $0 += 1
                        run = $0
                    }
                    if run == 1 {
                        firstCommandStarted.signal()
                        _ = firstCommandMayFinish.wait(timeout: .now() + 1)
                    }
                    return AccountCommandOutput(
                        status: 255,
                        stdout: "",
                        stderr: "Control socket connect: Connection refused"
                    )
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_KWT_JSON\n[]",
                    stderr: ""
                )
            }
        )
        let service = KwtInventoryService(client: client, lease: lease)
        let firstLoad = Task<KwtHostInventory, Error> {
            try await service.load(from: .ssh(ssh))
        }

        let didStartFirst = await BlockingTask.run {
            firstCommandStarted.wait(timeout: .now() + 1) == .success
        }
        #expect(didStartFirst)
        let secondLoad = Task<KwtHostInventory, Error> {
            try await service.load(from: .ssh(ssh))
        }
        let borrowedBeforeInvalidation = await BlockingTask.run {
            laterBorrowStarted.wait(timeout: .now() + 0.2) == .success
        }
        #expect(!borrowedBeforeInvalidation)
        firstCommandMayFinish.signal()

        await #expect(throws: KwtInventoryError.self) {
            try await firstLoad.value
        }
        let inventory = try await secondLoad.value

        #expect(inventory.projects.isEmpty)
        #expect(leaseBorrows.load() == 2)
        #expect(leaseGenerations.load() == 2)
    }

    @Test("unusable remote connection stops remaining projects")
    func unusableRemoteConnectionStopsRemainingProjects() async {
        let ssh = SSHHostInfo(user: "tester", hostname: "builder", port: nil)
        let projectRuns = LockedValue(0)
        let invalidations = LockedValue(0)
        let connection = KwtSSHConnection(
            arguments: ["-S", "/tmp/kwt.sock"],
            routeIdentity: "route-one",
            generation: 1,
            invalidate: { invalidations.withLock { $0 += 1 } }
        )
        let client = KwtInventoryClient(
            remoteRunner: { _, _, command in
                if command.contains("projects --json") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_KWT_JSON\n" +
                            #"[{"repository":"one","name":"one","path":"/one","registration_fingerprint":"one-fingerprint"},{"repository":"two","name":"two","path":"/two","registration_fingerprint":"two-fingerprint"}]"#,
                        stderr: ""
                    )
                }
                if command.contains("workspace list --json") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_KWT_JSON\n[]",
                        stderr: ""
                    )
                }
                projectRuns.withLock { $0 += 1 }
                return AccountCommandOutput(
                    status: 255,
                    stdout: "",
                    stderr: "Control socket connect(/tmp/kwt.sock): Connection refused"
                )
            }
        )

        await #expect(throws: KwtInventoryError.commandFailed(
            host: "tester@builder",
            status: 255
        )) {
            try await client.load(
                from: .ssh(ssh),
                sshConnection: connection
            )
        }
        #expect(projectRuns.load() == 1)
        #expect(invalidations.load() == 1)
    }

    @Test("remote inventory invalidates a lost daemon master")
    func invalidatesLostRemoteMaster() async {
        let invalidations = LockedValue(0)
        let ssh = SSHHostInfo(user: "tester", hostname: "builder", port: nil)
        let connection = KwtSSHConnection(
            arguments: ["-F", "/dev/null", "-S", "/tmp/kwt.sock"],
            routeIdentity: "route-one",
            generation: 1,
            invalidate: { invalidations.withLock { $0 += 1 } }
        )
        let client = KwtInventoryClient(
            remoteRunner: { _, _, _ in
                AccountCommandOutput(
                    status: 255,
                    stdout: "",
                    stderr: "Control socket connect(/tmp/kwt.sock): Connection refused"
                )
            }
        )

        await #expect(throws: KwtInventoryError.self) {
            try await client.load(
                from: .ssh(ssh),
                sshConnection: connection
            )
        }
        #expect(invalidations.load() == 1)
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
            remoteRunner: { host, arguments, command in
                #expect(host == ssh)
                #expect(arguments == ["-F", "NUL", "-S", #"C:\kwt.sock"#])
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
                    ? #"[{"name":"hub","path":"C:\\hub","session_name":"kwt-workspace-dir-hub-abc","session_live":false,"tmux_socket_name":"kwt","tmux_attach_mode":"direct"}]"#
                    : "[]"
                return AccountCommandOutput(
                    status: 0,
                    stdout: "PowerShell banner without newline"
                        + "GHOSTHUB_KWT_JSON\r\n\(json)\r\n",
                    stderr: ""
                )
            },
            remoteBinaryRevision: revision
        )

        let inventory = try await client.load(
            from: .ssh(ssh),
            sshConnectionArguments: ["-F", "NUL", "-S", #"C:\kwt.sock"#]
        )

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
                            #"[{"repository":"one","name":"one","path":"/one","registration_fingerprint":"one-fingerprint"},{"repository":"two","name":"two","path":"/two","registration_fingerprint":"two-fingerprint"}]"#
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

    @Test("a protected refresh can publish an unresolved endpoint")
    func protectedRefreshCanClearSocket() {
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
                tmuxSocketName: "kwt-pr-0123456789abcdef",
                tmuxAttachMode: .protected
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
                    tmuxSocketName: nil,
                    tmuxAttachMode: .protected
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
        #expect(merged.worktrees[0].tmuxSocketName == nil)
        #expect(merged.worktrees[0].tmuxAttachMode == .protected)
    }

    @Test("an unresolved protected refresh retains generation identity")
    func unresolvedProtectedRefreshRetainsGeneration() {
        let hostID = UUID()
        let projectID = UUID()
        let generation = "0123456789abcdef0123456789abcdef"
        let socketName = "kwt-pr-0123456789abcdef"
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: [ProjectSummary(
                id: projectID,
                hostID: hostID,
                scopedKey: "repo",
                name: "repo",
                rootPath: "/repo"
            )],
            worktrees: [WorktreeSummary(
                id: UUID(),
                hostID: hostID,
                projectID: projectID,
                name: "feature",
                path: "/repo-feature",
                branch: "feature/protected",
                generation: generation,
                tmuxSessionName: "kwt-repo-feature",
                tmuxSocketName: socketName,
                tmuxAttachMode: .protected
            )]
        )
        func inventory(generation: String?) -> KwtHostInventory {
            KwtHostInventory(projects: [KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "repo",
                    name: "repo",
                    path: "/repo",
                    lastTouched: nil
                ),
                worktrees: [KwtWorktreeRecord(
                    path: "/repo-feature",
                    branch: "feature/protected",
                    commitHash: "abc",
                    isMain: false,
                    createdAt: nil,
                    generation: generation,
                    repository: "repo",
                    sessionName: "kwt-repo-feature",
                    tmuxSocketName: nil,
                    tmuxAttachMode: .protected
                )],
                warning: nil
            )])
        }

        let incomplete = KwtSnapshotMerger.merge(
            inventory(generation: nil),
            hostID: hostID,
            into: snapshot
        )
        let restored = KwtSnapshotMerger.merge(
            inventory(generation: generation),
            hostID: hostID,
            into: incomplete
        )

        #expect(incomplete.worktrees[0].generation == generation)
        #expect(incomplete.worktrees[0].tmuxSocketName == nil)
        #expect(incomplete.worktrees[0].tmuxAttachMode == .protected)
        #expect(restored.worktrees[0].generation == generation)
        #expect(restored.worktrees[0].tmuxSocketName == nil)
        #expect(restored.worktrees[0].tmuxAttachMode == .protected)
    }

    @Test("generationless replacements do not inherit protected identity")
    func generationlessReplacementsDoNotInheritProtectedIdentity() {
        let hostID = UUID()
        let projectID = UUID()
        let generation = "0123456789abcdef0123456789abcdef"
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: [ProjectSummary(
                id: projectID,
                hostID: hostID,
                scopedKey: "repo",
                name: "repo",
                rootPath: "/repo"
            )],
            worktrees: [WorktreeSummary(
                id: UUID(),
                hostID: hostID,
                projectID: projectID,
                name: "feature",
                path: "/repo-feature",
                branch: "feature/original",
                generation: generation,
                tmuxSessionName: "kwt-repo-original",
                tmuxSocketName: "protected-socket"
            )]
        )
        let replacements = [
            (
                branch: "feature/replacement",
                isMain: false,
                session: "kwt-repo-original"
            ),
            (
                branch: "feature/original",
                isMain: true,
                session: "kwt-repo-original"
            ),
            (
                branch: "feature/original",
                isMain: false,
                session: "kwt-repo-replacement"
            ),
        ]

        for replacement in replacements {
            let inventory = KwtHostInventory(projects: [KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "repo",
                    name: "repo",
                    path: "/repo",
                    lastTouched: nil
                ),
                worktrees: [KwtWorktreeRecord(
                    path: "/repo-feature",
                    branch: replacement.branch,
                    commitHash: "def",
                    isMain: replacement.isMain,
                    createdAt: nil,
                    generation: nil,
                    repository: "repo",
                    sessionName: replacement.session,
                    tmuxSocketName: nil
                )],
                warning: nil
            )])

            let merged = KwtSnapshotMerger.merge(
                inventory,
                hostID: hostID,
                into: snapshot
            )

            #expect(merged.worktrees[0].generation == nil)
            #expect(merged.worktrees[0].tmuxSocketName == nil)
        }
    }

    @Test(
        "authoritative endpoint replaces cached generation endpoint",
        arguments: ["same-generation-socket", nil] as [String?]
    )
    func authoritativeEndpointReplacesCachedGenerationEndpoint(
        _ generationSocketName: String?
    ) {
        let hostID = UUID()
        let unrelatedProjectID = UUID()
        let targetProjectID = UUID()
        let unrelatedWorktreeID = UUID()
        let generation = "0123456789abcdef0123456789abcdef"
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: [
                ProjectSummary(
                    id: unrelatedProjectID,
                    hostID: hostID,
                    scopedKey: "repo-a",
                    name: "repo-a",
                    rootPath: "/repo-a"
                ),
                ProjectSummary(
                    id: targetProjectID,
                    hostID: hostID,
                    scopedKey: "repo-b",
                    name: "repo-b",
                    rootPath: "/repo-b"
                ),
            ],
            worktrees: [
                WorktreeSummary(
                    id: unrelatedWorktreeID,
                    hostID: hostID,
                    projectID: unrelatedProjectID,
                    name: "unrelated",
                    path: "/reused-path",
                    branch: "feature/unrelated",
                    generation: "fedcba9876543210fedcba9876543210",
                    tmuxSessionName: "kwt-repo-a-unrelated",
                    tmuxSocketName: "same-path-socket"
                ),
                WorktreeSummary(
                    id: UUID(),
                    hostID: hostID,
                    projectID: targetProjectID,
                    name: "target",
                    path: "/old-path",
                    branch: "feature/target",
                    generation: generation,
                    tmuxSessionName: "kwt-repo-b-target",
                    tmuxSocketName: generationSocketName
                ),
            ]
        )
        let inventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "repo-a",
                    name: "repo-a",
                    path: "/repo-a",
                    lastTouched: nil
                ),
                worktrees: [KwtWorktreeRecord(
                    path: "/reused-path",
                    branch: "feature/unrelated",
                    commitHash: "def",
                    isMain: false,
                    createdAt: nil,
                    generation: "fedcba9876543210fedcba9876543210",
                    repository: "repo-a",
                    sessionName: "kwt-repo-a-unrelated",
                    tmuxSocketName: "same-path-socket"
                )],
                warning: nil
            ),
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "repo-b",
                    name: "repo-b",
                    path: "/repo-b",
                    lastTouched: nil
                ),
                worktrees: [KwtWorktreeRecord(
                    path: "/reused-path",
                    branch: "feature/target",
                    commitHash: "abc",
                    isMain: false,
                    createdAt: nil,
                    generation: generation,
                    repository: "repo-b",
                    sessionName: "kwt-repo-b-target",
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

        #expect(merged.worktrees.count == 2)
        let unrelated = merged.worktrees.first {
            $0.projectID == unrelatedProjectID
        }
        let target = merged.worktrees.first {
            $0.projectID == targetProjectID
        }
        #expect(unrelated?.id == unrelatedWorktreeID)
        #expect(target?.id != unrelated?.id)
        #expect(target?.tmuxSocketName == nil)
        #expect(target?.tmuxAttachMode == .direct)
    }

    @Test("noncanonical generations do not transfer socket identity")
    func rejectsNoncanonicalGenerationForSocketIdentity() {
        let hostID = UUID()
        let projectID = UUID()
        let generation = "legacy-generation"
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: [ProjectSummary(
                id: projectID,
                hostID: hostID,
                scopedKey: "repo",
                name: "repo",
                rootPath: "/repo"
            )],
            worktrees: [WorktreeSummary(
                id: UUID(),
                hostID: hostID,
                projectID: projectID,
                name: "unrelated",
                path: "/old-path",
                branch: "feature/unrelated",
                generation: generation,
                tmuxSessionName: "kwt-repo-unrelated",
                tmuxSocketName: "protected-socket"
            )]
        )
        let inventory = KwtHostInventory(projects: [KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "repo",
                name: "repo",
                path: "/repo",
                lastTouched: nil
            ),
            worktrees: [KwtWorktreeRecord(
                path: "/new-path",
                branch: "feature/target",
                commitHash: "abc",
                isMain: false,
                createdAt: nil,
                generation: generation,
                repository: "repo",
                sessionName: "kwt-repo-target",
                tmuxSocketName: nil
            )],
            warning: nil
        )])

        let merged = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: snapshot
        )

        #expect(merged.worktrees.count == 1)
        #expect(merged.worktrees[0].tmuxSocketName == nil)
    }

    @Test("a canonical replacement cannot inherit a reused path socket")
    func canonicalReplacementDoesNotInheritPathSocket() {
        let hostID = UUID()
        let projectID = UUID()
        let replacementGeneration = "fedcba9876543210fedcba9876543210"
        let snapshot = WorkspaceSnapshot(
            hosts: [.fixture(id: hostID)],
            projects: [ProjectSummary(
                id: projectID,
                hostID: hostID,
                scopedKey: "repo",
                name: "repo",
                rootPath: "/repo"
            )],
            worktrees: [WorktreeSummary(
                id: UUID(),
                hostID: hostID,
                projectID: projectID,
                name: "old-generation",
                path: "/reused-path",
                branch: "feature/old",
                generation: "0123456789abcdef0123456789abcdef",
                tmuxSessionName: "kwt-repo-old",
                tmuxSocketName: "protected-socket"
            )]
        )
        let inventory = KwtHostInventory(projects: [KwtProjectInventory(
            project: KwtProjectRecord(
                repository: "repo",
                name: "repo",
                path: "/repo",
                lastTouched: nil
            ),
            worktrees: [KwtWorktreeRecord(
                path: "/reused-path",
                branch: "feature/replacement",
                commitHash: "abc",
                isMain: false,
                createdAt: nil,
                generation: replacementGeneration,
                repository: "repo",
                sessionName: "kwt-repo-replacement",
                tmuxSocketName: nil
            )],
            warning: nil
        )])

        let merged = KwtSnapshotMerger.merge(
            inventory,
            hostID: hostID,
            into: snapshot
        )

        #expect(merged.worktrees.count == 1)
        #expect(merged.worktrees[0].generation == replacementGeneration)
        #expect(merged.worktrees[0].tmuxSocketName == nil)
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

    @Test("partial project failure retains omitted cached worktrees")
    func retainsWorktreesOmittedByPartialProjectFailure() {
        let project = KwtProjectRecord(
            repository: "repo",
            name: "repo",
            path: "/repo",
            lastTouched: nil
        )
        let refreshed = KwtWorktreeRecord(
            path: "/repo",
            branch: "main",
            commitHash: "def",
            isMain: true,
            createdAt: nil,
            generation: "refreshed-generation",
            repository: "repo",
            sessionName: "kwt-repo-main"
        )
        let omitted = KwtWorktreeRecord(
            path: "/worktrees/feature",
            branch: "feature",
            commitHash: "abc",
            isMain: false,
            createdAt: nil,
            generation: "omitted-generation",
            repository: "repo",
            sessionName: "kwt-repo-feature"
        )
        let previous = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [omitted],
                warning: nil
            ),
        ])
        let partial = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: project,
                worktrees: [refreshed],
                warning: "temporary failure"
            ),
        ])

        let retained = partial.retainingFailedProjectWorktrees(from: previous)

        #expect(retained.projects[0].worktrees == [refreshed, omitted])
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
                "repo": [
                    KwtWorktreeIdentity(
                        path: removed.path,
                        generation: "removed-generation"
                    ),
                ],
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
                "repo": [
                    KwtWorktreeIdentity(
                        path: replacement.path,
                        generation: "removed-generation"
                    ),
                ],
            ]
        )

        #expect(retained.projects[0].worktrees == [replacement])
    }

    @Test("partial refresh does not inherit a replaced repository's worktrees")
    func partialRefreshRejectsSamePathReplacementCache() {
        let staleWorktree = KwtWorktreeRecord(
            path: "/worktrees/stale",
            branch: "stale",
            commitHash: "abc",
            isMain: false,
            createdAt: nil,
            repository: "old-repo",
            sessionName: "kwt-old-stale"
        )
        let previous = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "old-repo",
                    name: "old",
                    path: "/repo",
                    lastTouched: nil
                ),
                worktrees: [staleWorktree],
                warning: nil
            ),
        ])
        let replacement = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "new-repo",
                    name: "new",
                    path: "/repo",
                    lastTouched: nil
                ),
                worktrees: [],
                warning: "temporary failure"
            ),
        ])

        let retained = replacement.retainingFailedProjectWorktrees(
            from: previous
        )

        #expect(retained.projects[0].worktrees.isEmpty)
    }

    @Test("worktree exclusions apply only to their own repository")
    func exclusionsApplyOnlyToOwnRepository() {
        let reassigned = KwtWorktreeRecord(
            path: "/worktrees/reassigned",
            branch: "reassigned",
            commitHash: "abc",
            isMain: false,
            createdAt: nil,
            generation: "shared-generation",
            repository: "other-repo",
            sessionName: "kwt-other-reassigned"
        )
        let inventory = KwtHostInventory(projects: [
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: "other-repo",
                    name: "other",
                    path: "/other",
                    lastTouched: nil
                ),
                worktrees: [reassigned],
                warning: nil
            ),
        ])

        let retained = inventory.retainingFailedProjectWorktrees(
            from: nil,
            excludingWorktrees: [
                "repo": [
                    KwtWorktreeIdentity(
                        path: reassigned.path,
                        generation: "shared-generation"
                    ),
                ],
            ]
        )

        #expect(retained.projects[0].worktrees == [reassigned])
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
        let project = ProjectSummary(
            id: UUID(),
            hostID: hostID,
            scopedKey: "repo",
            name: "repo",
            rootPath: "/code/repo"
        )
        let worktree = WorktreeSummary(
            id: UUID(),
            hostID: hostID,
            projectID: project.id,
            name: "main",
            path: "/code/repo",
            branch: "main"
        )
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
            projects: [project],
            worktrees: [worktree]
        )

        let overlaid = HostInventoryOverlay.applyRuntimeSessions(
            tmuxSessionsByHost: [hostID: [discoveredSession]],
            to: storedSnapshot
        )

        #expect(overlaid.hosts[0].tmuxSessions == [discoveredSession])
        #expect(overlaid.projects == [project])
        #expect(overlaid.worktrees == [worktree])
    }

    @Test("tmux inventory authority does not require reachability state")
    func tmuxAuthorityIsIndependentOfReachability() {
        let hostID = UUID()
        let stored = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: hostID,
                name: "build-box",
                kind: .remote,
                platform: .linux,
                tmuxInventoryIsAuthoritative: false
            )],
            projects: [],
            worktrees: []
        )

        let overlaid = HostInventoryOverlay.applyRuntimeSessions(
            tmuxSessionsByHost: [:],
            tmuxAuthoritativeHostIDs: [hostID],
            to: stored
        )

        #expect(overlaid.hosts[0].tmuxInventoryIsAuthoritative)
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

        let overlaid = HostInventoryOverlay.applyRuntimeSessions(
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

    @Test("Zellij inventory overlays only Zellij runtime state")
    func zellijInventoryIsAdditive() {
        let hostID = UUID()
        let project = ProjectSummary(
            id: UUID(),
            hostID: hostID,
            scopedKey: "repo",
            name: "repo",
            rootPath: "/code/repo"
        )
        let worktree = WorktreeSummary(
            id: UUID(),
            hostID: hostID,
            projectID: project.id,
            name: "main",
            path: "/code/repo",
            branch: "main"
        )
        let tmux = TmuxSessionSummary(
            name: "tmux-kept",
            managed: false,
            windows: []
        )
        let herdr = HerdrSessionSummary(
            name: "herdr-kept",
            isDefault: false,
            state: .running
        )
        let stored = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: hostID,
                name: "build-box",
                kind: .remote,
                platform: .linux,
                tmuxSessions: [tmux],
                herdrSessions: [herdr],
                herdrAvailable: true,
                zellijSessions: [ZellijSessionSummary(name: "stale")]
            )],
            projects: [project],
            worktrees: [worktree]
        )
        let zellij = ZellijSessionSummary(name: "editor")

        let overlaid = HostInventoryOverlay.applyRuntimeSessions(
            tmuxSessionsByHost: [:],
            zellijSessionsByHost: [hostID: [zellij]],
            zellijAvailabilityByHost: [hostID: true],
            to: stored
        )

        #expect(overlaid.hosts[0].zellijSessions == [zellij])
        #expect(overlaid.hosts[0].zellijAvailable)
        #expect(overlaid.hosts[0].tmuxSessions == [tmux])
        #expect(overlaid.hosts[0].herdrSessions == [herdr])
        #expect(overlaid.hosts[0].herdrAvailable)
        #expect(overlaid.projects == [project])
        #expect(overlaid.worktrees == [worktree])
    }

    @Test("Zellij runtime inventory preserves noncanonical KWT paths")
    func zellijRuntimeInventorySkipsKwtPathNormalization() {
        let hostID = UUID()
        let project = ProjectSummary(
            id: UUID(),
            hostID: hostID,
            scopedKey: "repo",
            name: "repo",
            rootPath: "/code/./repo"
        )
        let worktree = WorktreeSummary(
            id: UUID(),
            hostID: hostID,
            projectID: project.id,
            name: "main",
            path: "/code/repo/../repo",
            branch: "main"
        )
        let stored = WorkspaceSnapshot(
            hosts: [HostSummary(
                id: hostID,
                name: "build-box",
                kind: .remote,
                platform: .linux
            )],
            projects: [project],
            worktrees: [worktree]
        )

        let overlaid = HostInventoryOverlay.applyRuntimeSessions(
            tmuxSessionsByHost: [:],
            zellijSessionsByHost: [
                hostID: [ZellijSessionSummary(name: "editor")],
            ],
            zellijAvailabilityByHost: [hostID: true],
            to: stored
        )

        #expect(overlaid.projects[0].rootPath == "/code/./repo")
        #expect(overlaid.worktrees[0].path == "/code/repo/../repo")
    }
}
