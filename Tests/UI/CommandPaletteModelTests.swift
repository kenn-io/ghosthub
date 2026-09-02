import Foundation
import GhosthubTestSupport
import GhosthubTerminalSupport
@testable import GhosthubUI
import GhosthubWorkspace
import Testing

struct CommandPaletteModelTests {
    @Test("command palette includes global actions and ordered worktrees")
    func commandPaletteIncludesGlobalActionsAndOrderedWorktrees() {
        let commands = makeCommandPaletteCommands()

        commands.expectCommandContains(
            title: "Hide Sidebar", shortcut: .toggleSidebar
        )
        commands.expectCommandNotContains(title: "Add Repository")
        commands.expectCommandContains(
            title: "New Worktree in ghosthub",
            shortcut: .newWorktree
        )
        commands.expectCommandNotContains(
            title: "Import Pull Request in ghosthub"
        )
        commands.expectCommandContains(
            title: "Previous Sibling", shortcut: .previousSibling
        )
        commands.expectCommandContains(
            title: "Next Sibling", shortcut: .nextSibling
        )
        commands.expectCommandContains(
            title: "Use Light Appearance", expectNilShortcut: true
        )
        commands.expectCommandContains(
            title: "Use Dark Appearance", expectNilShortcut: true
        )
        commands.expectCommandContains(
            title: "Follow System Appearance", expectNilShortcut: true
        )
        commands.expectCommandContains(
            title: "Open Appearance Settings", expectNilShortcut: true
        )
        commands.expectCommandContains(
            title: "Open Terminal Settings", expectNilShortcut: true
        )
        commands.expectCommandContains(
            title: "Open Integrations Settings", expectNilShortcut: true
        )
        commands.expectCommandNotContains(
            title: "Hide CPU & Memory in Pane Headers"
        )
        commands.expectCommandContains(
            title: "Open Ghosthub config directory",
            expectNilShortcut: true
        )
        commands.expectCommandContains(
            title: "Reload Configuration",
            shortcut: .reloadConfiguration
        )
        commands.expectCommandNotContains(title: "Launch Layout: Claude Driver")
        commands.expectCommandNotContains(title: "Focus Worktree Shell")
        commands.expectCommandNotContains(title: "Focus Agent Session")
        commands.expectCommandNotContains(title: "Focus Console Panel")

        let worktreeCommands = commands.filter { command in
            guard case let .select(target) = command.action else {
                return false
            }
            guard case .worktree = target else {
                return false
            }
            return true
        }

        #expect(
            worktreeCommands.map(\.title) == [
                "Switch to Worktree: primary checkout",
                "Switch to Worktree: sidebar-nav",
                "Switch to Worktree: review-fixes",
                "Switch to Worktree: release",
                "Switch to Worktree: worker-rollout",
            ]
        )
        #expect(worktreeCommands.allSatisfy { $0.shortcut == nil })
    }

    @Test("scene-dependent application commands follow availability")
    func sceneDependentCommandsFollowAvailability() {
        let commands = makeCommandPaletteCommands(
            availableApplicationShortcuts: [
                .find,
                .nextSibling,
                .splitDown,
            ]
        )

        commands.expectCommandContains(
            title: "Find in Terminal", shortcut: .find
        )
        commands.expectCommandNotContains(title: "Previous Sibling")
        commands.expectCommandContains(title: "Next Sibling")
        commands.expectCommandNotContains(title: "Split Right")
        commands.expectCommandContains(title: "Split Down")

        let unavailable = makeCommandPaletteCommands(
            availableApplicationShortcuts: []
        )
        unavailable.expectCommandNotContains(title: "Find in Terminal")
    }

    @Test("worktree commands follow persisted sidebar order")
    func worktreeCommandsFollowPersistedSidebarOrder() {
        let bootstrap = WorkspaceBootstrap.preview()
        let baseline = WorkspaceSidebarModel.sections(
            in: bootstrap.snapshot
        ).flatMap { $0.projects.flatMap(\.worktrees) }
        let rawOrder = [baseline[1].id, baseline[0].id]
            .map(\.uuidString)
            .joined(separator: "\n")
        let commands = makeCommandPaletteCommands(
            worktreeOrderRawValue: rawOrder
        ).filter {
            if case .select(.worktree(_)) = $0.action {
                return true
            }
            return false
        }

        #expect(commands[0].action == .select(.worktree(baseline[1].id)))
        #expect(commands[0].shortcut == nil)
        #expect(commands[1].action == .select(.worktree(baseline[0].id)))
        #expect(commands[1].shortcut == nil)
    }

    @Test("command palette omits settings commands when settings are unavailable")
    func commandPaletteOmitsSettingsCommandsWhenSettingsAreUnavailable() {
        let commands = makeCommandPaletteCommands(supportsSettings: false)

        #expect(
            !commands.contains { command in
                if case .openSettings = command.action {
                    return true
                }
                return false
            }
        )
        commands.expectCommandNotContains(
            title: "Hide CPU & Memory in Pane Headers"
        )
    }

    @Test("command palette omits web inbox command")
    func commandPaletteOmitsWebInboxCommand() {
        let commands = makeCommandPaletteCommands()

        commands.expectCommandNotContains(title: "Open Inbox")
    }

    @Test("active connected sessions offer one-shot theme application")
    func activeSessionOffersThemeApplication() throws {
        let host = HostSummary.fixture(platform: .macOS)
        let active = WorkspaceTmuxSessionSelection(
            hostID: host.id,
            name: "review"
        )
        let commands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            selection: WorkspaceSelection(selectedHostID: host.id),
            activeTmuxSession: active,
            activeTmuxSessionIsConnected: true,
            activeTmuxSessionCanApplyTheme: true
        )

        let command = try #require(commands.first {
            $0.title == "Apply Theme to Current Session"
        })
        #expect(command.action == .applyThemeToCurrentTmuxSession(active))
        #expect(command.subtitle.contains("review"))
        #expect(command.subtitle.contains("every attached client"))
        #expect(command.shortcut == nil)
    }

    @Test("Herdr lifecycle commands follow availability and session state")
    func herdrLifecycleCommands() {
        let hostID = UUID()
        let host = HostSummary.fixture(
            id: hostID,
            herdrSessions: [
                .init(name: "api", isDefault: false, state: .running),
                .init(name: "sleeping", isDefault: false, state: .stopped),
                .init(name: "default", isDefault: true, state: .stopped),
            ],
            herdrAvailable: true
        )
        let commands = makeCommandPaletteCommands(
            snapshot: .fixture(hosts: [host]),
            selection: .init(selectedHostID: hostID)
        )

        #expect(commands.contains {
            $0.action == .newHerdrSession(hostID)
        })
        #expect(commands.contains {
            $0.action == .stopHerdrSession(.init(
                hostID: hostID,
                name: "api"
            ))
        })
        #expect(commands.contains {
            $0.action == .restartHerdrSession(.init(
                hostID: hostID,
                name: "sleeping"
            ))
        })
        #expect(commands.contains {
            $0.action == .deleteHerdrSession(.init(
                hostID: hostID,
                name: "sleeping"
            ))
        })
        #expect(!commands.contains {
            $0.action == .deleteHerdrSession(.init(
                hostID: hostID,
                name: "default"
            ))
        })
    }

    @Test("unavailable sessions omit one-shot theme application")
    func unavailableSessionsOmitThemeApplication() {
        let host = HostSummary.fixture(platform: .macOS)
        let active = WorkspaceTmuxSessionSelection(
            hostID: host.id,
            name: "review"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [],
            worktrees: []
        )
        let selection = WorkspaceSelection(selectedHostID: host.id)
        let cases: [(WorkspaceTmuxSessionSelection?, Bool, Bool)] = [
            (nil, true, true),
            (active, false, true),
            (active, true, false),
        ]

        for (activeSession, connected, eligible) in cases {
            let commands = makeCommandPaletteCommands(
                snapshot: snapshot,
                selection: selection,
                activeTmuxSession: activeSession,
                activeTmuxSessionIsConnected: connected,
                activeTmuxSessionCanApplyTheme: eligible
            )
            commands.expectCommandNotContains(
                title: "Apply Theme to Current Session"
            )
        }

        let windowsHost = HostSummary.fixture(platform: .windows)
        let windowsSession = WorkspaceTmuxSessionSelection(
            hostID: windowsHost.id,
            name: "pwsh"
        )
        let windowsCommands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [windowsHost],
                projects: [],
                worktrees: []
            ),
            selection: WorkspaceSelection(
                selectedHostID: windowsHost.id
            ),
            activeTmuxSession: windowsSession,
            activeTmuxSessionIsConnected: true,
            activeTmuxSessionCanApplyTheme: false
        )
        windowsCommands.expectCommandNotContains(
            title: "Apply Theme to Current Session"
        )
    }

    @Test("command filtering matches titles subtitles and keywords")
    func commandFilteringMatchesTitlesSubtitlesAndKeywords() {
        let commands = makeCommandPaletteCommands(
            isSidebarVisible: false,
            isSidePanelVisible: true,
            interfaceAppearance: .dark
        )
        commands.expectCommandFilter(
            query: "release office",
            yieldsTitles: ["Switch to Worktree: release"]
        )
        commands.expectCommandFilter(
            query: "force dark appearance",
            yieldsTitles: ["Use Dark Appearance (Current)"]
        )
        commands.expectCommandFilter(
            query: "config finder",
            yieldsTitles: ["Open Ghosthub config directory"]
        )
    }

    @Test("command palette excludes stale rows")
    func commandPaletteExcludesStaleRows() {
        let host = HostSummary.fixture(
            id: UUID(uuidString: "6F0934D0-7D80-45AE-BDB4-13A765827902")!,
            name: "Build Box"
        )
        let activeProject = ProjectSummary.fixture(
            id: UUID(uuidString: "64134145-FEDE-4170-976C-69EF6D4DDB4D")!,
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/srv/ghosthub"
        )
        let staleProject = ProjectSummary.fixture(
            id: UUID(uuidString: "BF0A2603-9C1C-4757-9002-4A45AB83C841")!,
            hostID: host.id,
            name: "ghosthub-old",
            rootPath: "/srv/ghosthub-old",
            isStale: true
        )
        let activeWorktree = WorktreeSummary.fixture(
            id: UUID(uuidString: "FC0CC6CC-7F55-49A0-B6E4-A33D7065C60D")!,
            hostID: host.id,
            projectID: activeProject.id,
            name: "main",
            path: "/srv/ghosthub",
            branch: "main"
        )
        let staleWorktree = WorktreeSummary.fixture(
            id: UUID(uuidString: "7DEB2666-B27B-456F-B0FE-19CC58A170B1")!,
            hostID: host.id,
            projectID: staleProject.id,
            name: "legacy",
            path: "/srv/ghosthub-old",
            branch: "legacy",
            isStale: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [activeProject, staleProject],
            worktrees: [activeWorktree, staleWorktree]
        )
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: staleProject.id,
            selectedWorktreeID: staleWorktree.id
        )

        let commands = makeCommandPaletteCommands(
            snapshot: snapshot, selection: selection
        )

        commands.expectCommandNotContains(title: "Select Project: ghosthub-old")
        commands.expectCommandNotContains(title: "Switch to Worktree: legacy")
        commands.expectCommandNotContains(title: "New Worktree in ghosthub-old")
    }

    @Test("command palette selection commands follow sidebar rows")
    func commandPaletteSelectionCommandsFollowSidebarRows() {
        let hostID = UUID()
        let projectID = UUID()
        let worktreeID = UUID()
        let worktree = WorktreeSummary.fixture(
            id: worktreeID,
            hostID: hostID,
            projectID: projectID,
            name: "",
            path: "/repo-main",
            branch: "main",
            isPrimary: true
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(id: hostID, name: "This Mac"),
            ],
            projects: [
                .fixture(
                    id: projectID,
                    hostID: hostID,
                    name: "",
                    rootPath: "/repo"
                ),
            ],
            worktrees: [worktree]
        )
        let selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: projectID,
            selectedWorktreeID: worktreeID
        )

        let commands = makeCommandPaletteCommands(
            snapshot: snapshot,
            selection: selection
        )

        commands.expectCommandContains(
            title: "Select Project: Untitled",
            expectNilShortcut: true
        )
        commands.expectCommandContains(
            title: "New Worktree in Untitled",
            shortcut: .newWorktree
        )
        commands.expectCommandContains(
            title: "Switch to Worktree: Untitled",
            expectNilShortcut: true
        )

        let sidebarWorktreeRow = WorkspaceSidebarModel.sections(
            in: snapshot
        )[0].projects[0].worktreeRows[0]
        let command = commands.first {
            $0.title == "Switch to Worktree: Untitled"
        }
        #expect(command?.action == .select(sidebarWorktreeRow.target))
    }

    @Test("project commands remain searchable by root path with platform subtitles")
    func projectCommandsRemainSearchableByRootPathWithPlatformSubtitles() throws {
        let hostID = UUID()
        let projectID = UUID()
        let project = ProjectSummary.fixture(
            id: projectID,
            hostID: hostID,
            name: "app",
            rootPath: "/Users/wesm/code/app",
            platformURL: "https://github.com/acme/app",
            platformCoverage: "active"
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [
                .fixture(id: hostID, name: "This Mac"),
            ],
            projects: [project],
            worktrees: []
        )
        let selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: projectID
        )

        let commands = makeCommandPaletteCommands(
            snapshot: snapshot,
            selection: selection
        )

        let selectProject = try #require(commands.first {
            $0.title == "Select Project: app"
        })
        #expect(selectProject.subtitle == "acme/app")
        commands.expectCommandFilter(
            query: "/Users/wesm/code/app",
            yieldsTitles: [
                "New Worktree in app",
                "Select Project: app",
            ]
        )
    }

    @Test("command palette omits create-worktree command for synthesized projects")
    func commandPaletteOmitsCreateWorktreeForSynthesizedProjects() {
        let host = HostSummary.fixture(
            id: UUID(uuidString: "6F0934D0-7D80-45AE-BDB4-13A765827902")!,
            name: "Build Box"
        )
        // A synthesized project is platform-linked with active coverage but has
        // no local checkout, so it must not offer a create-worktree command.
        let synthesizedProject = ProjectSummary.fixture(
            id: UUID(uuidString: "BF0A2603-9C1C-4757-9002-4A45AB83C841")!,
            hostID: host.id,
            name: "orphan",
            rootPath: "",
            isSynthesized: true
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [synthesizedProject],
            worktrees: []
        )
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: synthesizedProject.id
        )

        let commands = makeCommandPaletteCommands(
            snapshot: snapshot, selection: selection
        )

        commands.expectCommandNotContains(title: "Create Worktree in orphan")
    }

    @Test("command palette omits worktree creation when kwt is unavailable")
    func commandPaletteOmitsCreateWorktreeWithoutKwt() {
        var host = HostSummary.fixture(
            id: UUID(uuidString: "6F0934D0-7D80-45AE-BDB4-13A765827902")!,
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "build-box"
        )
        host.remoteDiagnostics = [.missingKwtCapability]
        let project = ProjectSummary.fixture(
            id: UUID(uuidString: "BF0A2603-9C1C-4757-9002-4A45AB83C841")!,
            hostID: host.id,
            name: "docbank",
            rootPath: "/srv/docbank"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [project],
            worktrees: []
        )
        let selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: project.id
        )

        let commands = makeCommandPaletteCommands(
            snapshot: snapshot,
            selection: selection
        )

        commands.expectCommandNotContains(title: "New Worktree in docbank")
    }

    @Test("command palette omits layout commands without a launch target")
    func commandPaletteOmitsLayoutCommandsWithoutLaunchTarget() {
        let bootstrap = WorkspaceBootstrap.preview()

        var selection = bootstrap.selection
        selection.selectedProjectID = nil
        selection.selectedWorktreeID = nil

        let commands = makeCommandPaletteCommands(
            selection: selection
        )

        #expect(!commands.contains { $0.id.hasPrefix("layout-") })
    }

    @Test("kwt worktree creation is available without PR import")
    func kwtWorktreeCreationIsAvailableWithoutPRImport() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let linkedProject = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/code/ghosthub",
            platformURL: "https://github.com/user/ghosthub",
            platformCoverage: "active"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [linkedProject],
            worktrees: []
        )
        let commands = makeCommandPaletteCommands(
            snapshot: snapshot,
            selection: WorkspaceSelection(
                selectedHostID: host.id,
                selectedProjectID: linkedProject.id
            )
        )
        commands.expectCommandNotContains(title: "Add Repository")
        commands.expectCommandContains(
            title: "New Worktree in ghosthub",
            shortcut: .newWorktree
        )
        commands.expectCommandNotContains(title: "Import Pull Request in ghosthub")
    }

    @Test("GitHub kwt projects expose pull request import")
    func githubKwtProjectExposesPullRequestImport() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        var project = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/code/ghosthub"
        )
        project.scopedKey = "github.com/kenn-io/ghosthub"
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [project],
            worktrees: []
        )
        let commands = makeCommandPaletteCommands(
            snapshot: snapshot,
            selection: WorkspaceSelection(
                selectedHostID: host.id,
                selectedProjectID: project.id
            )
        )

        commands.expectCommandContains(
            title: "Import Pull Request in ghosthub",
            shortcut: .importPullRequest
        )
    }

    @Test("host and tmux lifecycle actions are discoverable")
    func hostAndTmuxLifecycleActionsAreDiscoverable() throws {
        let host = HostSummary.fixture(
            name: "DGX Spark",
            kind: .remote,
            platform: .linux,
            sshDestination: "wesm@dgx-spark",
            tmuxSessions: [
                TmuxSessionSummary(
                    name: "training",
                    managed: false,
                    windows: [],
                    serverPID: "4242",
                    sessionID: "$3",
                    createdAt: "1785190000"
                ),
            ]
        )
        let project = ProjectSummary.fixture(
            hostID: host.id,
            name: "msgvault",
            rootPath: "/code/msgvault"
        )
        var worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id,
            name: "pr-519",
            path: "/worktrees/pr-519"
        )
        worktree.tmuxSessionName = "kwt-msgvault-pr-519"
        worktree.tmuxSocketName = "kwt-pr-0123456789abcdef"
        worktree.tmuxAttachMode = .protected
        let protectedSession = WorkspaceTmuxSessionSelection(
            hostID: host.id,
            name: "kwt-msgvault-pr-519",
            worktreeID: worktree.id,
            worktreePath: worktree.path,
            socketName: "kwt-pr-0123456789abcdef",
            tmuxAttachMode: .protected
        )
        let commands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [project],
                worktrees: [worktree]
            ),
            selection: WorkspaceSelection(selectedHostID: host.id)
        )

        commands.expectCommandContains(
            title: "New tmux session on DGX Spark"
        )
        commands.expectCommandContains(
            title: "Add Project on DGX Spark"
        )
        commands.expectCommandContains(
            title: "Open tmux session: training"
        )
        commands.expectCommandContains(
            title: "Kill tmux session: training"
        )
        commands.expectCommandContains(
            title: "Open tmux session: kwt-msgvault-pr-519"
        )
        commands.expectCommandNotContains(
            title: "Kill tmux session: kwt-msgvault-pr-519"
        )

        let activeCommands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [project],
                worktrees: [worktree]
            ),
            selection: WorkspaceSelection(selectedHostID: host.id),
            activeTmuxSession: protectedSession,
            activeTmuxSessionIsConnected: true
        )
        let protectedKill = try #require(activeCommands.first {
            $0.title == "Kill tmux session: kwt-msgvault-pr-519"
        })
        #expect(
            protectedKill.action == .killTmuxSession(protectedSession)
        )
    }

    @Test("running Herdr sessions expose searchable open and stop commands")
    func runningHerdrSessionCommands() throws {
        let host = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            herdrSessions: [
                HerdrSessionSummary(name: "api", isDefault: true, state: .running),
            ]
        )
        let commands = makeCommandPaletteCommands(
            snapshot: .fixture(hosts: [host]),
            selection: WorkspaceSelection(selectedHostID: host.id)
        )

        let open = try #require(commands.first {
            $0.title == "Open Herdr session: api"
        })
        #expect(open.action == .openHerdrSession(
            WorkspaceHerdrSessionSelection(hostID: host.id, name: "api")
        ))
        #expect(open.keywords.contains("Build Box"))
        let stop = try #require(commands.first {
            $0.title == "Stop Herdr session: api"
        })
        #expect(CommandPaletteModel.filteredCommands(
            commands,
            query: "api build box"
        ).map(\.id) == [open.id, stop.id])
        #expect(!commands.contains { command in
            command.title.contains("api")
                && (command.title.localizedCaseInsensitiveContains("kill")
                    || command.title.localizedCaseInsensitiveContains("theme")
                    || command.title.localizedCaseInsensitiveContains("delete"))
        })
    }

    @Test("active Zellij sessions expose create, open, and kill commands")
    func zellijSessionCommands() {
        let host = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "dev@builder",
            zellijSessions: [ZellijSessionSummary(name: "api")],
            zellijAvailable: true
        )
        let commands = makeCommandPaletteCommands(
            snapshot: .fixture(hosts: [host]),
            selection: WorkspaceSelection(selectedHostID: host.id)
        )
        let selection = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "api"
        )

        #expect(commands.contains {
            $0.action == .newZellijSession(host.id)
        })
        #expect(commands.contains {
            $0.action == .openZellijSession(selection)
        })
        #expect(commands.contains {
            $0.action == .killZellijSession(selection)
        })
        #expect(CommandPaletteModel.filteredCommands(
            commands,
            query: "zellij api build"
        ).count == 2)
    }

    @Test("Windows hosts do not offer POSIX project registration")
    func windowsHostsHideAddProject() {
        let host = HostSummary.fixture(
            name: "ARM Builder",
            kind: .remote,
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        )
        let commands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            selection: WorkspaceSelection(selectedHostID: host.id)
        )

        commands.expectCommandContains(
            title: "New tmux session on ARM Builder"
        )
        commands.expectCommandNotContains(
            title: "Add Project on ARM Builder"
        )
    }

    @Test("hidden tmux session patterns remove lifecycle commands")
    func hiddenTmuxSessionsAreNotDiscoverable() {
        let host = HostSummary.fixture(
            name: "This Mac",
            tmuxSessions: [
                TmuxSessionSummary(
                    name: "forge-2ce60210419f1730",
                    managed: false,
                    windows: []
                ),
                TmuxSessionSummary(
                    name: "homelab",
                    managed: false,
                    windows: []
                ),
            ]
        )

        let commands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            selection: WorkspaceSelection(selectedHostID: host.id),
            tmuxSessionVisibility: TmuxSessionVisibility(
                hiddenPatterns: ["forge-*"]
            )
        )

        commands.expectCommandNotContains(
            title: "Open tmux session: forge-2ce60210419f1730"
        )
        commands.expectCommandContains(title: "Open tmux session: homelab")
    }

    @Test("exposed kwt session keeps one worktree-aware lifecycle command")
    func exposedKwtSessionDeduplicatesLifecycleCommands() throws {
        let host = HostSummary.fixture(
            tmuxSessions: [
                TmuxSessionSummary(
                    name: "kwt-ghosthub-main",
                    managed: false,
                    windows: [],
                    serverPID: "4242",
                    sessionID: "$3",
                    createdAt: "1785190000"
                ),
            ]
        )
        let project = ProjectSummary.fixture(hostID: host.id)
        var worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id
        )
        worktree.tmuxSessionName = "kwt-ghosthub-main"
        let commands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [project],
                worktrees: [worktree]
            ),
            selection: WorkspaceSelection(selectedHostID: host.id),
            tmuxSessionVisibility: TmuxSessionVisibility(
                hideKwtManagedSessions: false
            )
        )

        let openCommands = commands.filter {
            if case let .openTmuxSession(session) = $0.action {
                return session.name == "kwt-ghosthub-main"
            }
            return false
        }
        let killCommands = commands.filter {
            if case let .killTmuxSession(session) = $0.action {
                return session.name == "kwt-ghosthub-main"
            }
            return false
        }
        let open = try #require(openCommands.first)
        let kill = try #require(killCommands.first)
        let expected = try #require(
            WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        )
        #expect(openCommands.count == 1)
        #expect(killCommands.count == 1)
        #expect(open.action == .openTmuxSession(expected))
        #expect(kill.action == .killTmuxSession(expected))
    }

    @Test("directory workspace supplies canonical lifecycle commands")
    func directoryWorkspaceSuppliesCanonicalLifecycleCommands() throws {
        let host = HostSummary.fixture(tmuxSessions: [.init(
            name: "kwt-workspace-dir-hub",
            managed: false,
            windows: [],
            serverPID: "4242",
            sessionID: "$3",
            createdAt: "1785190000"
        )])
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: host.id,
            name: "hub",
            path: "/srv/hub",
            tmuxSessionName: "kwt-workspace-dir-hub",
            sessionLive: true
        )
        let commands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: [],
                directoryWorkspaces: [directory]
            ),
            selection: WorkspaceSelection(selectedHostID: host.id)
        )

        let expected = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )
        let open = try #require(commands.first {
            $0.action == .openTmuxSession(expected)
        })
        let kill = try #require(commands.first {
            $0.action == .killTmuxSession(expected)
        })
        #expect(open.title == "Open tmux session: kwt-workspace-dir-hub")
        #expect(kill.title == "Kill tmux session: kwt-workspace-dir-hub")
    }

    @Test("exposed directory session keeps one workspace-aware command")
    func exposedDirectorySessionDeduplicatesLifecycleCommands() {
        let sessionName = "kwt-workspace-dir-hub"
        let host = HostSummary.fixture(tmuxSessions: [.init(
            name: sessionName,
            managed: false,
            windows: [],
            serverPID: "4242",
            sessionID: "$3",
            createdAt: "1785190000"
        )])
        let directory = DirectoryWorkspaceSummary(
            id: UUID(),
            hostID: host.id,
            name: "hub",
            path: "/srv/hub",
            tmuxSessionName: sessionName,
            sessionLive: true
        )
        let commands = makeCommandPaletteCommands(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: [],
                directoryWorkspaces: [directory]
            ),
            selection: WorkspaceSelection(selectedHostID: host.id),
            tmuxSessionVisibility: TmuxSessionVisibility(
                hideKwtManagedSessions: false
            )
        )
        let expected = WorkspaceSidebarModel.tmuxSessionSelection(
            for: directory
        )
        let openCommands = commands.filter {
            if case let .openTmuxSession(session) = $0.action {
                return session.name == sessionName
            }
            return false
        }
        let killCommands = commands.filter {
            if case let .killTmuxSession(session) = $0.action {
                return session.name == sessionName
            }
            return false
        }

        #expect(openCommands.map(\.action) == [.openTmuxSession(expected)])
        #expect(killCommands.map(\.action) == [.killTmuxSession(expected)])
    }

    @Test("import PR command hidden without GitHub-linked projects")
    func importPRCommandHiddenWithoutGitHubLink() {
        let host = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let unlinkedProject = ProjectSummary.fixture(
            hostID: host.id,
            name: "ghosthub",
            rootPath: "/code/ghosthub"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host],
            projects: [unlinkedProject],
            worktrees: []
        )
        let commands = makeCommandPaletteCommands(
            snapshot: snapshot,
            selection: WorkspaceSelection(
                selectedHostID: host.id,
                selectedProjectID: unlinkedProject.id
            )
        )
        commands.expectCommandNotContains(
            title: "Import Pull Request in ghosthub"
        )
    }

    @Test("worktree switching remains while retired deletion stays hidden")
    func worktreeSwitchingRemainsWithoutDeletion() throws {
        let env = makeCommandPaletteWorkspaceEnvironment(
            worktrees: [
                { worktree in
                    worktree.name = "main"
                    worktree.branch = "main"
                    worktree.isPrimary = true
                },
                { worktree in
                    worktree.name = "feature/api-keyboard"
                    worktree.branch = "feature/api-keyboard"
                    worktree.path = "/tmp/delete-api-keyboard"
                    worktree.isPrimary = false
                },
            ]
        )
        let commands = makeCommandPaletteCommands(
            snapshot: env.snapshot,
            selection: env.selection
        )

        commands.expectCommandNotContains(
            title: "Delete Worktree: main"
        )

        let filtered = CommandPaletteModel.filteredCommands(
            commands,
            query: "api-keyboard"
        )
        let switchIndex = try #require(
            filtered.firstIndex {
                $0.title == "Switch to Worktree: feature/api-keyboard"
            }
        )
        #expect(filtered[switchIndex].title
            == "Switch to Worktree: feature/api-keyboard")
        commands.expectCommandNotContains(
            title: "Delete Worktree: feature/api-keyboard"
        )
    }

    @Test("command palette omits unavailable remote import commands")
    func commandPaletteOmitsUnavailableRemoteImportCommands() {
        let env = makeCommandPaletteWorkspaceEnvironment(
            hostConfig: { host in
                host.kind = .remote
                host.platform = .linux
                host.sshDestination = "rpi5-ssd"
                host.lastKnownReachable = true
                host.lastSeenAt = Date(timeIntervalSince1970: 1_700_000_000)
                host.remoteCapabilities = .fixture(
                    commands: .fixture(
                        worktreeImportPullRequest: false
                    ),
                    dependencies: .fixture(gh: false)
                )
                host.remoteDiagnostics = [
                    RemoteHostDiagnostic(
                        code: .missingGh,
                        severity: .warning,
                        summary: "Missing gh",
                        recoverySuggestion:
                        "Install GitHub CLI (`gh`) on the remote host to import pull requests."
                    ),
                ]
            },
            projectConfig: { project in
                project.name = "ghosthub"
                project.rootPath = "/srv/ghosthub"
                project.platformURL = "https://github.com/kenn-io/ghosthub"
                project.platformCoverage = "active"
            },
            worktrees: []
        )

        let commands = makeCommandPaletteCommands(
            snapshot: env.snapshot, selection: env.selection
        )

        commands.expectCommandContains(
            title: "New Worktree in ghosthub",
            shortcut: .newWorktree
        )
        commands.expectCommandNotContains(
            title: "Import Pull Request in ghosthub"
        )
    }
}

private func makeCommandPaletteCommands(
    snapshot: WorkspaceSnapshot? = nil,
    selection: WorkspaceSelection? = nil,
    activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
    activeTmuxSessionIsConnected: Bool = false,
    activeTmuxSessionCanApplyTheme: Bool = false,
    isWorkspacesRoute: Bool = true,
    isSidebarVisible: Bool = true,
    isSidePanelVisible: Bool = false,
    interfaceAppearance: AppearancePreference = .system,
    tmuxSessionVisibility: TmuxSessionVisibility = TmuxSessionVisibility(),
    supportsSettings: Bool = true,
    worktreeOrderRawValue: String = "",
    tmuxSessionOrderRawValue: String = "",
    availableApplicationShortcuts: Set<ApplicationShortcutAction> = [
        .previousSibling,
        .nextSibling,
        .splitRight,
        .splitDown,
    ]
) -> [WorkspaceCommandItem] {
    let bootstrap = WorkspaceBootstrap.preview()
    let snap = snapshot ?? bootstrap.snapshot
    let sel = selection ?? bootstrap.selection
    return CommandPaletteModel.commands(
        in: snap,
        selection: sel,
        activeTmuxSession: activeTmuxSession,
        activeTmuxSessionIsConnected: activeTmuxSessionIsConnected,
        activeTmuxSessionCanApplyTheme:
        activeTmuxSessionCanApplyTheme,
        isWorkspacesRoute: isWorkspacesRoute,
        isSidebarVisible: isSidebarVisible,
        isSidePanelVisible: isSidePanelVisible,
        interfaceAppearance: interfaceAppearance,
        tmuxSessionVisibility: tmuxSessionVisibility,
        supportsSettings: supportsSettings,
        worktreeOrderRawValue: worktreeOrderRawValue,
        tmuxSessionOrderRawValue: tmuxSessionOrderRawValue,
        availableApplicationShortcuts: availableApplicationShortcuts
    )
}

private func makeCommandPaletteWorkspaceEnvironment(
    hostConfig: (inout HostSummary) -> Void = { _ in },
    projectConfig: (inout ProjectSummary) -> Void = { _ in },
    worktrees worktreeConfigs: [(inout WorktreeSummary) -> Void] = [
        { worktree in
            worktree.name = "main"
            worktree.branch = "main"
        },
    ]
) -> (
    snapshot: WorkspaceSnapshot,
    selection: WorkspaceSelection,
    host: HostSummary,
    project: ProjectSummary,
    worktrees: [WorktreeSummary]
) {
    var host = HostSummary.fixture()
    hostConfig(&host)

    var project = ProjectSummary.fixture(hostID: host.id)
    projectConfig(&project)

    let worktrees = worktreeConfigs.map { config in
        var worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id
        )
        config(&worktree)
        return worktree
    }
    let snapshot = WorkspaceSnapshot(
        hosts: [host],
        projects: [project],
        worktrees: worktrees
    )
    let selection = WorkspaceSelection(
        selectedHostID: host.id,
        selectedProjectID: project.id,
        selectedWorktreeID: worktrees.first?.id
    )
    return (snapshot, selection, host, project, worktrees)
}

private extension [WorkspaceCommandItem] {
    func expectCommandContains(
        title: String,
        shortcut: ApplicationShortcutAction? = nil,
        expectNilShortcut: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let found = contains {
            guard $0.title == title else { return false }
            if expectNilShortcut {
                return $0.shortcut == nil
            }
            return shortcut == nil || $0.shortcutAction == shortcut
        }
        #expect(
            found,
            "Expected to find command '\(title)'",
            sourceLocation: sourceLocation
        )
    }

    func expectCommandNotContains(
        title: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let found = contains { $0.title == title }
        #expect(
            !found,
            "Expected NOT to find command '\(title)'",
            sourceLocation: sourceLocation
        )
    }

    func expectCommandFilter(
        query: String,
        yieldsTitles expectedTitles: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let filtered = CommandPaletteModel.filteredCommands(
            self,
            query: query
        )
        #expect(
            filtered.map(\.title) == expectedTitles,
            sourceLocation: sourceLocation
        )
    }
}
