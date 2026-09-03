import AppKit
import Foundation
import GhosthubPersistence
import GhosthubTerminalSupport
import GhosthubTestSupport
import GhosthubTmux
import GhosthubUI
import GhosthubWorkspace
import Synchronization
import SwiftUI
import Testing
@testable import GhosthubApp

private final class ShortcutFocusWindow: NSWindow {
    var keyState = false

    override var isKeyWindow: Bool { keyState }
}

@Suite("Workspace application shortcuts", .serialized)
@MainActor
struct WorkspaceApplicationShortcutTests {
    @Test("a presented log viewer takes Find priority over a borrowed session")
    func presentedLogViewerTakesFindPriority() async throws {
        let environment = try setupHostEnvironment()
        let store = SceneTmuxSurfaceStoreStub()
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport
                .previewPaneSplitter(identity: identity)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "find-session"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: store)
        await waitUntilMainActor {
            store.surface.terminalFindController.isAvailable
        }
        let borrowedController = TerminalFindController(
            isAvailable: true,
            sessionProvider: { nil }
        )
        store.surface.terminalFindController = borrowedController

        model.isFocusedWindow = true
        model.isLogViewerPresented = true
        _ = try #require(model.logViewerTerminalView())
        let logSurface = try #require(
            model.terminalCoordinator.surfaceEntries().first {
                $0.key.target == .logViewer
            }?.view
        )
        let logController = TerminalFindController(
            isAvailable: true,
            sessionProvider: { nil }
        )
        logSurface.terminalFindController = logController
        let logView = try #require(model.logViewerTerminalView())
        let hostingView = NSHostingView(rootView: logView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var containsSearchField: ((NSView) -> Bool)!
        containsSearchField = { view in
            view is NSSearchField
                || view.subviews.contains { containsSearchField($0) }
        }

        #expect(model.performApplicationShortcut(.find))
        #expect(logController.isOpen)
        #expect(!borrowedController.isOpen)
        await waitUntilMainActor {
            containsSearchField(hostingView)
        }
        #expect(containsSearchField(hostingView))

        await model.shutdown()
    }

    @Test("standalone Find routing survives responder changes")
    func standaloneFindRoutingSurvivesResponderChanges() async throws {
        let environment = try setupHostEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot
        )
        model.isFocusedWindow = true
        model.isLogViewerPresented = true
        _ = try #require(model.logViewerTerminalView())
        let surface = try #require(
            model.terminalCoordinator.surfaceEntries().first {
                $0.key.target == .logViewer
            }?.view
        )
        let navigations = Mutex<[TerminalFindDirection]>([])
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: {
                TerminalFindSession(
                    search: { _, _ in
                        .success(.result(.match(total: 2, selected: nil)))
                    },
                    navigate: { direction, _ in
                        navigations.withLock { $0.append(direction) }
                        return .success(.result(.match(
                            total: 2,
                            selected: nil
                        )))
                    },
                    close: { nil }
                )
            }
        )
        surface.terminalFindController = controller

        try #require(model.performApplicationShortcut(.find))
        controller.updateQuery("needle")
        await waitUntilMainActor { controller.canNavigate }
        model.isLogViewerPresented = false

        #expect(model.performApplicationShortcut(.findNext))
        await waitUntilMainActor { navigations.withLock { $0.count } == 1 }
        #expect(navigations.withLock { $0 } == [.next])
        #expect(model.performApplicationShortcut(.hideFindBar))
        #expect(!controller.isOpen)

        await model.shutdown()
    }

    @Test("Find shortcuts route to the active terminal and follow its state")
    func findShortcutRouting() async throws {
        let environment = try setupHostEnvironment()
        let store = SceneTmuxSurfaceStoreStub()
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot,
            nativeTmuxSurfaceStore: store,
            nativeTmuxPathProvider: {
                successfulTmuxResolution("/usr/bin/tmux")
            },
            nativeTmuxPaneSplitter: WorkspaceTmuxTestSupport
                .previewPaneSplitter(identity: identity)
        )
        let selection = WorkspaceTmuxSessionSelection(
            hostID: environment.host.id,
            name: "find-session"
        )
        model.openBorrowedTmuxSession(selection)
        await launchActiveTmuxSurface(model, store: store)
        await waitUntilMainActor {
            store.surface.terminalFindController.isAvailable
        }

        let navigations = Mutex<[TerminalFindDirection]>([])
        let controller = TerminalFindController(
            isAvailable: true,
            debounce: .zero,
            sessionProvider: {
                TerminalFindSession(
                    search: { _, _ in
                        .success(.result(.match(total: 3, selected: nil)))
                    },
                    navigate: { direction, _ in
                        navigations.withLock { $0.append(direction) }
                        return .success(.result(.match(
                            total: 3,
                            selected: nil
                        )))
                    },
                    close: { nil }
                )
            }
        )
        store.surface.terminalFindController = controller
        model.isFocusedWindow = true

        #expect(model.availablePaletteApplicationShortcuts.contains(.find))
        #expect(model.performApplicationShortcut(.find))
        #expect(controller.isOpen)
        #expect(model.availablePaletteApplicationShortcuts.contains(
            .hideFindBar
        ))
        controller.updateQuery("needle")
        await waitUntilMainActor { controller.canNavigate }
        #expect(model.availablePaletteApplicationShortcuts.isSuperset(
            of: [.findNext, .findPrevious]
        ))
        #expect(model.performApplicationShortcut(.findNext))
        #expect(model.performApplicationShortcut(.findPrevious))
        await waitUntilMainActor { navigations.withLock { $0.count } == 2 }
        #expect(navigations.withLock { $0 } == [.next, .previous])
        #expect(model.performApplicationShortcut(.hideFindBar))
        #expect(!controller.isOpen)
        await waitUntilMainActor {
            store.surface.keyboardFocusRequestCount == 1
        }

        controller.open()
        model.hideBorrowedTmuxSession(selection)
        #expect(!controller.isOpen)
        await model.shutdown()
    }

    @Test("sibling availability requires a resolvable peer")
    func siblingAvailability() async throws {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let only = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "only"
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [project], worktrees: [only]
            )
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: only.id
        )

        #expect(!model.canPerformSiblingShortcut(.nextSibling))

        model.snapshot.worktrees.append(WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "peer"
        ))
        #expect(model.canPerformSiblingShortcut(.nextSibling))
        #expect(model.canPerformSiblingShortcut(.selectSibling2))
        #expect(!model.canPerformSiblingShortcut(.selectSibling3))
        await model.shutdown()
    }

    @Test("focused sibling navigation selects within the current project")
    func focusedSiblingNavigation() async throws {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let first = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "first"
        )
        let second = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "second"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host], projects: [project],
            worktrees: [first, second]
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: snapshot
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: first.id
        )

        #expect(!model.performApplicationShortcut(.nextSibling))
        model.isFocusedWindow = true
        #expect(model.performApplicationShortcut(.nextSibling))
        #expect(model.selection.selectedWorktreeID == second.id)
        #expect(model.performApplicationShortcut(.previousSibling))
        #expect(model.selection.selectedWorktreeID == first.id)
        await model.shutdown()
    }

    @Test("sibling shortcuts use the live workspace window focus")
    func siblingShortcutsUseLiveWindowFocus() async throws {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let first = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "first"
        )
        let second = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "second"
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [project],
                worktrees: [first, second]
            )
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: first.id
        )
        let window = ShortcutFocusWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        model.workspaceWindow = window
        let monitor = ShortcutMonitor(
            shortcuts: { ApplicationShortcutCatalog.compiledDefaults },
            perform: { action in
                model.performApplicationShortcut(action)
            }
        )
        let next = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))
        let previous = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ))

        window.keyState = true
        #expect(monitor.processForTesting(next) == nil)
        #expect(model.selection.selectedWorktreeID == second.id)
        #expect(monitor.processForTesting(previous) == nil)
        #expect(model.selection.selectedWorktreeID == first.id)

        window.keyState = false
        model.isFocusedWindow = true
        #expect(monitor.processForTesting(next) === next)
        #expect(model.selection.selectedWorktreeID == first.id)
        await model.shutdown()
    }

    @Test("Zellij presentation enables sibling navigation")
    func zellijSiblingNavigation() async throws {
        let host = HostSummary(
            id: UUID(),
            configKey: "local",
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            zellijSessions: [
                ZellijSessionSummary(name: "first"),
                ZellijSessionSummary(name: "second"),
            ],
            zellijAvailable: true
        )
        let store = RecordingNativeSessionSurfaceStore()
        let model = try makeModel(
            database: .inMemory(),
            localHostID: host.id,
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [], worktrees: []
            ),
            nativeZellijSurfaceStore: store,
            nativeZellijPathProvider: { _ in .success("/usr/bin/zellij") },
            zellijSessionValidationDiscovery: { _, _ in
                .available(["first", "second"])
            }
        )
        let first = WorkspaceZellijSessionSelection(
            hostID: host.id,
            name: "first"
        )

        model.openBorrowedZellijSession(first)
        await waitUntilMainActor {
            model.activeBorrowedZellijSelection == first
        }
        model.isFocusedWindow = true

        #expect(model.canPerformSiblingShortcut(.nextSibling))
        #expect(model.performApplicationShortcut(.nextSibling))
        await waitUntilMainActor {
            model.activeBorrowedZellijSelection?.name == "second"
        }
        #expect(model.activeBorrowedZellijSelection?.name == "second")
        await model.shutdown()
    }

    @Test("menu sibling navigation uses its captured scene")
    func menuSiblingNavigation() async throws {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        let first = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "first"
        )
        let second = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id, name: "second"
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [project],
                worktrees: [first, second]
            )
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: first.id
        )
        model.isFocusedWindow = false

        #expect(model.performApplicationShortcut(
            .nextSibling,
            invocation: .menu
        ))
        #expect(model.selection.selectedWorktreeID == second.id)
        await model.shutdown()
    }

    @Test("pull request import does not require worktree creation")
    func pullRequestImportWithoutCreation() async throws {
        let host = HostSummary.fixture(operationAvailability: [
            "worktreeCreate": .init(available: false),
            "pullRequestImport": .init(available: true),
        ])
        let project = ProjectSummary(
            id: UUID(),
            hostID: host.id,
            scopedKey: "github.com/example/project-a",
            name: "project-a",
            rootPath: "/tmp/project-a"
        )
        let snapshot = WorkspaceSnapshot(
            hosts: [host], projects: [project], worktrees: []
        )
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: snapshot
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id
        )
        model.isFocusedWindow = true

        #expect(!snapshot.canCreateWorktree(in: project))
        #expect(snapshot.canImportPullRequest(in: project))
        #expect(model.performApplicationShortcut(.importPullRequest))
        await model.shutdown()
    }

    @Test("worktree menu availability requires creation capability")
    func worktreeMenuAvailabilityRequiresCreation() async throws {
        let host = HostSummary.fixture(operationAvailability: [
            "worktreeCreate": .init(available: false),
        ])
        let project = ProjectSummary.fixture(hostID: host.id)
        let model = try makeModel(
            database: .inMemory(), localHostID: host.id,
            snapshot: WorkspaceSnapshot(
                hosts: [host], projects: [project], worktrees: []
            )
        )
        model.selection = .init(
            selectedHostID: host.id,
            selectedProjectID: project.id
        )
        model.isFocusedWindow = true

        #expect(!model.canCreateWorktreeInSelectedProject)
        #expect(!model.performApplicationShortcut(.newWorktree))
        await model.shutdown()
    }

    @Test("presentation actions report availability and mutate once")
    func presentationActions() async throws {
        let environment = try setupHostEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot
        )
        model.isFocusedWindow = true

        #expect(model.performApplicationShortcut(.commandPalette))
        #expect(model.isCommandPalettePresented)
        #expect(model.performApplicationShortcut(.openApplicationLog))
        #expect(model.isLogViewerPresented)
        #expect(!model.performApplicationShortcut(.splitRight))
        #expect(!model.performApplicationShortcut(.newHerdrSession))
        await model.shutdown()
    }

    @Test("menu-owned shortcuts read attached sheet eligibility at dispatch time")
    func menuOwnedShortcutsUseLiveSheetEligibility() async throws {
        let environment = try setupHostEnvironment()
        let model = try makeModel(
            database: environment.database,
            localHostID: environment.host.id,
            snapshot: environment.snapshot
        )
        model.isFocusedWindow = true
        let window = ShortcutFocusWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.keyState = true
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        model.workspaceWindow = window
        window.beginSheet(sheet) { _ in }
        #expect(window.attachedSheet === sheet)

        #expect(!model.performApplicationShortcut(.toggleSidebar))
        #expect(!model.performApplicationShortcut(
            .toggleSidebar,
            invocation: .menu
        ))
        #expect(!model.performApplicationShortcut(.commandPalette))
        #expect(!model.isCommandPalettePresented)

        window.endSheet(sheet)
        #expect(window.attachedSheet == nil)

        #expect(model.performApplicationShortcut(.toggleSidebar))
        #expect(model.performApplicationShortcut(.commandPalette))
        #expect(model.isCommandPalettePresented)
        await model.shutdown()
    }
}
