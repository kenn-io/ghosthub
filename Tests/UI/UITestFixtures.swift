import AppKit
import Foundation
import GhosthubTestSupport
import SwiftUI
import Testing
@testable import GhosthubUI
@testable import GhosthubWorkspace

// MARK: - AppKit View Testing Helpers

@MainActor
func hostView<Content: View>(
    _ rootView: Content,
    size: CGSize = CGSize(width: 360, height: 520)
) -> NSHostingView<Content> {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    return hostingView
}

@MainActor
func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants(of:))
}

// MARK: - Deterministic Test Identifiers

// MARK: - Test Date Constants

extension Date {
    static let testEarly = Date(
        timeIntervalSinceReferenceDate: 768_355_200
    )
    static let testReference = Date(
        timeIntervalSinceReferenceDate: 800_000_000
    )
}

// MARK: - Domain Model Fixtures

extension WorktreeSummary {
    func makeSession(
        id: UUID = UUID(),
        isAlive: Bool = true,
        lastOutputAt: Date? = nil
    ) -> TerminalSessionSummary {
        TerminalSessionSummary.fixture(
            id: id,
            hostID: hostID,
            worktreeID: self.id,
            isAlive: isAlive,
            lastOutputAt: lastOutputAt
        )
    }

}

extension TerminalSessionSummary {
    static func fixture(
        id: UUID = UUID(),
        hostID: UUID = UUID(),
        worktreeID: UUID? = nil,
        isAlive: Bool = true,
        lastOutputAt: Date? = nil
    ) -> TerminalSessionSummary {
        TerminalSessionSummary(
            id: id, hostID: hostID,
            worktreeID: worktreeID,
            isAlive: isAlive,
            lastOutputAt: lastOutputAt
        )
    }
}

extension WorktreeSummary {
    static func linkedFixture(
        number: Int,
        projectID: UUID = UUID(),
        name: String? = nil,
        isStale: Bool = false
    ) -> WorktreeSummary {
        .fixture(
            projectID: projectID,
            name: name ?? "wt-\(number)",
            path: "/\(number)",
            branch: "b\(number)",
            isStale: isStale,
            linkedPullRequestNumber: number
        )
    }
}

// MARK: - Workspace Environment Builder

struct WorkspaceEnvironment {
    var snapshot: WorkspaceSnapshot
    var selection: WorkspaceSelection
    var host: HostSummary
    var project: ProjectSummary
    var worktrees: [WorktreeSummary]
}

func makeWorkspaceEnvironment(
    hostConfig: (inout HostSummary) -> Void = { _ in },
    projectConfig: (inout ProjectSummary) -> Void = { _ in },
    worktrees worktreeConfigs: [(inout WorktreeSummary) -> Void] = [
        { $0.name = "main"
            $0.branch = "main" },
    ]
) -> WorkspaceEnvironment {
    var host = HostSummary.fixture()
    hostConfig(&host)

    var project = ProjectSummary.fixture(hostID: host.id)
    projectConfig(&project)

    var worktrees: [WorktreeSummary] = []
    for config in worktreeConfigs {
        var wt = WorktreeSummary.fixture(
            hostID: host.id, projectID: project.id
        )
        config(&wt)
        worktrees.append(wt)
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
    return WorkspaceEnvironment(
        snapshot: snapshot,
        selection: selection,
        host: host,
        project: project,
        worktrees: worktrees
    )
}

// MARK: - AppKit Interaction Helpers

@MainActor
func sidebarHostWindow<Content: View>(
    rootView: Content,
    size: CGSize
) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = NSHostingView(rootView: rootView)
    NSApplication.shared.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    return window
}

@MainActor
func viewDescendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(viewDescendants(of:))
}

@MainActor
func viewByAccessibilityID(
    _ identifier: String,
    in view: NSView
) -> NSView? {
    viewDescendants(of: view).first {
        $0.accessibilityIdentifier() == identifier
    }
}

@MainActor
func waitForAccessibilityView(
    id identifier: String,
    in view: NSView,
    timeout: TimeInterval = 5.0
) -> NSView? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let match = viewByAccessibilityID(identifier, in: view) {
            return match
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    return nil
}

@MainActor
func syntheticClick(
    at point: CGPoint,
    in view: NSView,
    window: NSWindow
) {
    let pointInWindow = view.convert(
        NSPoint(x: point.x, y: point.y), to: nil
    )
    let timestamp = ProcessInfo.processInfo.systemUptime
    let down = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: pointInWindow,
        modifierFlags: [],
        timestamp: timestamp,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
    let up = NSEvent.mouseEvent(
        with: .leftMouseUp,
        location: pointInWindow,
        modifierFlags: [],
        timestamp: timestamp + 0.01,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 0
    )
    if let down {
        window.sendEvent(down)
    }
    if let up {
        window.sendEvent(up)
    }
}

@MainActor
func syntheticMouseMoved(
    at point: CGPoint,
    in view: NSView,
    window: NSWindow
) {
    window.acceptsMouseMovedEvents = true
    let pointInWindow = view.convert(
        NSPoint(x: point.x, y: point.y), to: nil
    )
    let moved = NSEvent.mouseEvent(
        with: .mouseMoved,
        location: pointInWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
    )
    if let moved {
        window.sendEvent(moved)
    }
}

@MainActor
func syntheticHoverEntered(
    in view: NSView,
    window: NSWindow
) {
    let pointInWindow = view.convert(
        NSPoint(x: view.bounds.midX, y: view.bounds.midY),
        to: nil
    )
    let event = NSEvent.enterExitEvent(
        with: .mouseEntered,
        location: pointInWindow,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        trackingNumber: 0,
        userData: nil
    )
    if let event {
        view.mouseEntered(with: event)
    }
}

// MARK: - View Inspection Helpers

@MainActor
func waitUntilCondition(
    timeout: TimeInterval = 5.0,
    condition: @escaping () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

@MainActor
func containsText(_ value: String, in view: NSView) -> Bool {
    viewDescendants(of: view).contains { descendant in
        if let field = descendant as? NSTextField {
            return field.stringValue.contains(value)
        }
        return false
    }
}

@MainActor
func segmentedControls(
    in view: NSView
) -> [NSSegmentedControl] {
    viewDescendants(of: view).compactMap { $0 as? NSSegmentedControl }
}

@MainActor
func button(titled title: String, in view: NSView) -> NSButton? {
    viewDescendants(of: view).compactMap { $0 as? NSButton }
        .first { $0.title == title }
}

@MainActor
func settledButtonCount(
    in view: NSView,
    settlingFor timeout: TimeInterval = 0.3
) -> Int {
    RunLoop.main.run(until: Date().addingTimeInterval(timeout))
    return viewDescendants(of: view)
        .compactMap { $0 as? NSButton }.count
}

// MARK: - Command Palette Helpers

func makeCommands(
    snapshot: WorkspaceSnapshot? = nil,
    selection: WorkspaceSelection? = nil,
    isWorkspacesRoute: Bool = true,
    isSidebarVisible: Bool = true,
    isSidePanelVisible: Bool = false,
    isWebPreviewRequested: Bool = false,
    interfaceAppearance: AppearancePreference = .system,
    supportsSettings: Bool = true
) -> [WorkspaceCommandItem] {
    let bootstrap = WorkspaceBootstrap.preview()
    let snap = snapshot ?? bootstrap.snapshot
    let sel = selection ?? bootstrap.selection
    return CommandPaletteModel.commands(
        in: snap,
        selection: sel,
        isWorkspacesRoute: isWorkspacesRoute,
        isSidebarVisible: isSidebarVisible,
        isSidePanelVisible: isSidePanelVisible,
        isWebPreviewRequested: isWebPreviewRequested,
        interfaceAppearance: interfaceAppearance,
        supportsSettings: supportsSettings
    )
}

func makeHostCommand(
    for host: HostSummary
) throws -> WorkspaceCommandItem {
    let snapshot = WorkspaceSnapshot(
        hosts: [host], projects: [], worktrees: []
    )
    let commands = makeCommands(
        snapshot: snapshot,
        selection: WorkspaceSelection(selectedHostID: host.id)
    )
    return try #require(
        commands.first(where: {
            $0.title == "Select Host: \(host.name)"
        })
    )
}

// MARK: - Accessibility Descriptor Assertions

func expectDescriptor(
    _ descriptor: WorkspaceAccessibilityDescriptor,
    label: String? = nil,
    value: String? = nil,
    hint: String? = nil,
    hintContains: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    if let label {
        #expect(
            descriptor.label == label,
            sourceLocation: sourceLocation
        )
    }
    #expect(
        descriptor.value == value,
        sourceLocation: sourceLocation
    )
    if let hint {
        #expect(
            descriptor.hint == hint,
            sourceLocation: sourceLocation
        )
    }
    if let hintContains {
        #expect(
            descriptor.hint?.contains(hintContains) == true,
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - Command Array Assertion Helpers

extension [WorkspaceCommandItem] {
    func expectContains(
        title: String,
        shortcut: WorkspaceCommandShortcut? = nil,
        expectNilShortcut: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let found = contains {
            guard $0.title == title else { return false }
            if expectNilShortcut {
                return $0.shortcut == nil
            }
            return shortcut == nil || $0.shortcut == shortcut
        }
        #expect(
            found,
            "Expected to find command '\(title)'",
            sourceLocation: sourceLocation
        )
    }

    func expectNotContains(
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

    func expectFilter(
        query: String,
        yieldsTitles expectedTitles: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let filtered = CommandPaletteModel.filteredCommands(
            self, query: query
        )
        #expect(
            filtered.map(\.title) == expectedTitles,
            sourceLocation: sourceLocation
        )
    }
}
