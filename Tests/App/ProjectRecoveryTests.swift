import Foundation
import Testing
import GhosthubTestSupport
@testable import GhosthubApp
import GhosthubTransport
import GhosthubWorkspace

@Suite("Project folder recovery")
struct ProjectRecoveryTests {
    @Test("a folder that disappears after listing is quiet across refreshes")
    func folderDisappearsAfterListing() async throws {
        let fixture = try TempDirectoryFixture()
        let missing = fixture.childURL("missing").path
        let record = "{\"repository\":\"github.com/acme/widget\",\"name\":\"Widget\",\"path\":\"\(missing)\",\"registration_fingerprint\":\"observation\"}"
        let unresolved = record.dropLast() + ",\"path_issue\":\"missing\"}"
        let binary = try fixture.write("""
        #!/bin/sh
        case "$1 $2" in
          'projects --json') printf '%s\\n' '[\(record)]' ;;
          'projects recover') printf '%s\\n' '{"status":"unresolved","project":\(unresolved)}' ;;
          'workspace list') printf '[]\\n' ;;
          *) exit 9 ;;
        esac
        """, toRelativePath: "kwt")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let calls = LockedValue<[String]>([])
        let client = KwtInventoryClient(
            localRunner: { _, command in
                calls.withLock { $0.append(command) }
                let result = AccountCommandRunner.runProcess(
                    executable: "/bin/sh", arguments: ["-c", command], timeout: 5
                )
                return (result.status, result.stdout)
            },
            localBinaryPath: binary.path,
            recoveryAttempts: ProjectRecoveryAttempts()
        )
        for _ in 0 ..< 2 {
            let inventory = try await client.load(from: .local)
            #expect(inventory.projects[0].project.pathIssue == .unavailable)
            #expect(inventory.projects[0].warning == nil)
        }
        #expect(calls.load().filter { $0.contains("'projects' 'recover'") }.count == 1)
    }

    @Test("restoring a project allows a later missing-folder recovery")
    func restorationClearsAttempt() async {
        let attempts = ProjectRecoveryAttempts()
        let project = KwtProjectRecord(
            repository: "github.com/acme/widget",
            name: "Widget",
            path: "/code/widget",
            lastTouched: nil,
            registrationFingerprint: "observation"
        )
        #expect(await attempts.begin(project, on: .local))
        #expect(await !attempts.begin(project, on: .local))
        await attempts.finish(project, on: .local)
        #expect(await attempts.begin(project, on: .local))
    }

    @Test("missing folders retain cached worktrees and disable project mutations")
    func retainsWorktrees() {
        let host = HostSummary.fixture(id: UUID())
        let project = ProjectSummary(
            id: UUID(),
            hostID: host.id,
            scopedKey: "github.com/acme/widget",
            name: "Widget",
            rootPath: "/code/widget"
        )
        let worktree = WorktreeSummary(
            id: UUID(),
            hostID: host.id,
            projectID: project.id,
            scopedKey: "/code/widget",
            name: "main",
            path: "/code/widget",
            branch: "main",
            isPrimary: true,
            tmuxSessionName: "widget-main"
        )
        let inventory = KwtHostInventory(projects: [KwtProjectInventory(
            project: KwtProjectRecord(
                repository: project.scopedKey,
                name: project.name,
                path: project.rootPath,
                lastTouched: nil,
                pathIssue: .missing
            ),
            worktrees: [], warning: nil
        )])
        let snapshot = KwtSnapshotMerger.merge(
            inventory,
            hostID: host.id,
            into: WorkspaceSnapshot(hosts: [host], projects: [project], worktrees: [worktree])
        )
        #expect(snapshot.projects[0].id == project.id)
        #expect(snapshot.worktrees == [worktree])
        #expect(!snapshot.canCreateWorktree(in: snapshot.projects[0]))
        #expect(!snapshot.canImportPullRequest(in: snapshot.projects[0]))
    }

    @Test("missing folders stay project-scoped and automatic recovery runs once")
    func missingFolder() async throws {
        let calls = LockedValue<[String]>([])
        let project = #"{"repository":"github.com/acme/widget","name":"Widget","path":"/code/original","registration_fingerprint":"observation","path_issue":"missing"}"#
        let client = KwtInventoryClient(
            localRunner: { _, command in
                calls.withLock { $0.append(command) }
                if command.contains("projects --json") {
                    return (0, "GHOSTHUB_KWT_JSON\n[\(project)]")
                }
                if command.contains("'projects' 'recover'") {
                    return (
                        0,
                        "GHOSTHUB_KWT_JSON\n{\"status\":\"unresolved\",\"project\":\(project)}"
                    )
                }
                #expect(command.contains("workspace list --json"))
                return (0, "GHOSTHUB_KWT_JSON\n[]")
            },
            recoveryAttempts: ProjectRecoveryAttempts()
        )

        for _ in 0 ..< 2 {
            let result = try await client.load(from: .local)
            #expect(result.projects[0].project.pathIssue == .missing)
            #expect(result.projects[0].warning == nil)
            #expect(result.projectsWarning == nil)
        }
        #expect(calls.load().filter { $0.contains("'projects' 'recover'") }.count == 1)
    }

    @Test("recovered projects load worktrees from the new path")
    func recoveredFolder() async throws {
        let project = #"{"repository":"github.com/acme/widget","name":"Widget","path":"/code/original","registration_fingerprint":"observation","path_issue":"missing"}"#
        let recovered = #"{"repository":"github.com/acme/widget","name":"Widget","path":"/code/renamed","registration_fingerprint":"new-observation"}"#
        let client = KwtInventoryClient(
            localRunner: { _, command in
                if command.contains("projects --json") {
                    return (0, "GHOSTHUB_KWT_JSON\n[\(project)]")
                }
                if command.contains("'projects' 'recover'") {
                    return (
                        0,
                        "GHOSTHUB_KWT_JSON\n{\"status\":\"recovered\",\"project\":\(recovered)}"
                    )
                }
                if !command.contains("workspace list --json") {
                    #expect(command.contains("cd -- '/code/renamed'"))
                }
                return (0, "GHOSTHUB_KWT_JSON\n[]")
            },
            recoveryAttempts: ProjectRecoveryAttempts()
        )

        let result = try await client.load(from: .local)
        #expect(result.projects[0].project.path == "/code/renamed")
        #expect(result.projects[0].project.pathIssue == nil)
        #expect(result.projects[0].warning == nil)
    }
}
