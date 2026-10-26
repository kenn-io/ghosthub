import AppKit
import Foundation
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubUI

@Suite(.serialized)
@MainActor
struct WorktreeFlagViewTests {
    @Test(
        "real row actions flag primary and linked rows without attaching",
        arguments: [false, true]
    )
    func flagRows(dark: Bool) throws {
        let app = NSApplication.shared
        let wasEnhanced = app.value(forKey: "accessibilityEnhancedUserInterface")
        app.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { app.setValue(wasEnhanced, forKey: "accessibilityEnhancedUserInterface") }
        let fixture = try FlagStoreFixture()
        let store = fixture.store()
        var workspace = FlagTestWorkspace()
        workspace.snapshot.hosts[0].name = "This Mac"
        workspace.snapshot.projects[0].name = "Example"
        workspace.snapshot.worktrees[0].name = "main"
        workspace.snapshot.worktrees[0].isPrimary = true
        let primary = workspace.snapshot.worktrees[0]
        let linked = WorktreeSummary(
            id: UUID(), hostID: primary.hostID, projectID: primary.projectID,
            name: "feature/editor-shortcuts", path: "/code/example-editor",
            branch: "feature/editor-shortcuts",
            generation: String(repeating: "b", count: 32)
        )
        let sibling = WorktreeSummary(
            id: UUID(), hostID: primary.hostID, projectID: primary.projectID,
            name: "fix/reconnect", path: "/code/example-reconnect", branch: "fix/reconnect",
            generation: String(repeating: "c", count: 32)
        )
        workspace.snapshot.worktrees = [primary, linked, sibling]
        let snapshot = workspace.snapshot
        var selection = WorkspaceSelection(
            selectedHostID: primary.hostID, selectedProjectID: primary.projectID,
            selectedWorktreeID: linked.id
        )
        let originalSelection = selection
        var attachments = 0
        let view = hostView(
            WorkspaceSidebarView(
                snapshot: snapshot, sectionCache: WorkspaceSidebarSectionCache(),
                worktreeFlagStore: store,
                selection: Binding(get: { selection }, set: { selection = $0 }),
                visibility: WorktreeVisibility(),
                onOpenTmuxSession: { _, _ in attachments += 1 },
                onOpen: { _ in attachments += 1 }
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(dark ? .dark : .light),
            size: CGSize(width: 360, height: 440)
        )
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Ghosthub"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        defer { window.close() }
        func settle() {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            view.layoutSubtreeIfNeeded()
        }
        settle()
        for (value, attribute) in [
            (
                "sidebar-section-disclosure-projects:\(primary.hostID.uuidString)",
                "accessibilityIdentifier"
            ),
            ("Expand Example", "accessibilityLabel"),
        ] {
            let element = try #require(find(
                value,
                attribute: attribute,
                in: view
            ))
            _ = element.perform(NSSelectorFromString("accessibilityPerformPress"))
            settle()
        }
        for worktree in [primary, linked] {
            let row = try #require(find(worktree.name, attribute: "accessibilityLabel", in: view))
            let actions = try #require(row
                .value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction])
            let flag = try #require(actions.first { $0.name == "Flag Worktree" })
            try perform(flag)
            settle()
            let key = try #require(WorktreeFlagKey.resolve(worktreeID: worktree.id, in: snapshot))
            #expect(store.isFlagged(key))
            let flaggedRow = try #require(find(
                worktree.name,
                attribute: "accessibilityLabel",
                in: view
            ))
            #expect((flaggedRow.value(forKey: "accessibilityValue") as? String)?
                .contains("Flagged") == true)
            #expect(find(
                "worktree-actions-\(worktree.id.uuidString)",
                attribute: "accessibilityIdentifier",
                in: view
            ) != nil)
        }
        #expect(selection == originalSelection)
        #expect(attachments == 0)
        #expect(fixture.store().flaggedKeys == store.flaggedKeys)
        if let directory = ProcessInfo.processInfo
            .environment["GHOSTHUB_WORKTREE_FLAG_SCREENSHOT_DIR"] {
            try capture(
                view,
                to: URL(fileURLWithPath: directory)
                    .appendingPathComponent("worktree-flags-\(dark ? "dark" : "light").png")
            )
        }
        for worktree in [primary, linked] {
            let row = try #require(find(worktree.name, attribute: "accessibilityLabel", in: view))
            let actions = try #require(row
                .value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction])
            try perform(try #require(actions.first { $0.name == "Unflag Worktree" }))
            settle()
        }
        #expect(store.flaggedKeys.isEmpty)
        #expect(attachments == 0)
        #expect(selection == originalSelection)
    }

    private func find(_ value: String, attribute: String, in element: NSObject) -> NSObject? {
        if element.responds(to: NSSelectorFromString(attribute)),
           element.value(forKey: attribute) as? String == value {
            return element
        }
        guard element.responds(to: NSSelectorFromString("accessibilityChildren")),
              let children = element.value(forKey: "accessibilityChildren") as? [NSObject]
        else { return nil }
        return children.lazy.compactMap { find(value, attribute: attribute, in: $0) }.first
    }

    private func perform(_ action: NSAccessibilityCustomAction) throws {
        if let handler = action.handler {
            #expect(handler())
        } else {
            let target = try #require(action.target as? NSObject)
            let selector = try #require(action.selector)
            typealias Action = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
            let invoke = unsafeBitCast(target.method(for: selector), to: Action.self)
            #expect(invoke(target, selector, action))
        }
    }

    private func capture(_ view: NSView, to url: URL) throws {
        let frame = try #require(view.window?.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: url, options: .atomic)
    }
}
