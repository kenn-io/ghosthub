import AppKit
import SwiftUI
import Testing
@testable import GhosthubUI

/// Verifies that toggling the left sidebar or right side panel
/// does not destroy and recreate the terminal content subtree.
/// The invariant: terminal-hosting views must remain the same
/// AppKit instances across sidebar visibility changes.
@MainActor
struct SidebarToggleStabilityTests {
    @Test("left sidebar toggle preserves terminal content view identity")
    func leftSidebarTogglePreservesTerminalContent() {
        let env = StabilityTestEnvironment()

        let viewBefore = env.findStableContent()
        #expect(viewBefore != nil, "stable content should exist initially")

        env.isSidebarVisible = false
        env.settle()

        let viewAfter = env.findStableContent()
        #expect(viewAfter != nil, "stable content should exist after hiding sidebar")
        #expect(
            viewBefore === viewAfter,
            "terminal content view must be the same instance after sidebar toggle"
        )

        env.isSidebarVisible = true
        env.settle()

        let viewRestored = env.findStableContent()
        #expect(viewRestored != nil, "stable content should exist after restoring sidebar")
        #expect(
            viewBefore === viewRestored,
            "terminal content view must be the same instance after sidebar restore"
        )
    }

    @Test("right side panel toggle preserves main column view identity")
    func rightSidePanelTogglePreservesMainColumn() {
        let env = SidePanelStabilityTestEnvironment()

        let viewBefore = env.findStableContent()
        #expect(viewBefore != nil, "stable content should exist initially")

        env.isSidePanelVisible = true
        env.settle()

        let viewAfter = env.findStableContent()
        #expect(viewAfter != nil, "stable content should exist after showing side panel")
        #expect(
            viewBefore === viewAfter,
            "main column view must be the same instance after side panel toggle"
        )

        env.isSidePanelVisible = false
        env.settle()

        let viewRestored = env.findStableContent()
        #expect(viewRestored != nil, "stable content should exist after hiding side panel")
        #expect(
            viewBefore === viewRestored,
            "main column view must be the same instance after side panel hide"
        )
    }
}

// MARK: - Test Helpers

/// Mimics the RootView sidebar pattern: an HSplitView
/// with conditional sidebar content alongside a stable
/// terminal content view.
@MainActor
private final class StabilityTestEnvironment {
    var isSidebarVisible = true {
        didSet { updateView() }
    }
    private let window: NSWindow
    private let hostingView: NSHostingView<AnyView>
    private let stableID = "stability-test-content"

    init() {
        let view = AnyView(
            StableContentTestView(
                isSidebarVisible: true,
                stableID: stableID
            )
        )
        hostingView = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    func settle() {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func findStableContent() -> NSView? {
        findView(id: stableID, in: window.contentView!)
    }

    private func updateView() {
        hostingView.rootView = AnyView(
            StableContentTestView(
                isSidebarVisible: isSidebarVisible,
                stableID: stableID
            )
        )
        settle()
    }

    private func findView(id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id {
            return view
        }
        for subview in view.subviews {
            if let found = findView(id: id, in: subview) {
                return found
            }
        }
        return nil
    }
}

/// Mimics the left sidebar pattern from RootView.workspaceContent.
/// The stable content is always inside the HSplitView; only
/// the sidebar conditionally appears.
private struct StableContentTestView: View {
    let isSidebarVisible: Bool
    let stableID: String

    var body: some View {
        HSplitView {
            if isSidebarVisible {
                Color.gray
                    .frame(width: 256)
            }
            StableContentView(stableID: stableID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Exercises the former right-side-panel stability pattern.
@MainActor
private final class SidePanelStabilityTestEnvironment {
    var isSidePanelVisible = false {
        didSet { updateView() }
    }
    private let window: NSWindow
    private let hostingView: NSHostingView<AnyView>
    private let stableID = "stability-test-main-column"

    init() {
        let view = AnyView(
            SidePanelStableContentTestView(
                isSidePanelVisible: false,
                stableID: stableID
            )
        )
        hostingView = NSHostingView(rootView: view)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    func settle() {
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func findStableContent() -> NSView? {
        findView(id: stableID, in: window.contentView!)
    }

    private func updateView() {
        hostingView.rootView = AnyView(
            SidePanelStableContentTestView(
                isSidePanelVisible: isSidePanelVisible,
                stableID: stableID
            )
        )
        settle()
    }

    private func findView(id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id {
            return view
        }
        for subview in view.subviews {
            if let found = findView(id: id, in: subview) {
                return found
            }
        }
        return nil
    }
}

/// Mimics the right side panel pattern. The main column
/// is always inside the HStack; only the side panel
/// conditionally appears.
private struct SidePanelStableContentTestView: View {
    let isSidePanelVisible: Bool
    let stableID: String

    var body: some View {
        HStack(spacing: 0) {
            StableContentView(stableID: stableID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isSidePanelVisible {
                Color.blue
                    .frame(width: 320)
            }
        }
    }
}

/// A view that embeds a persistent NSView via
/// NSViewRepresentable, simulating a terminal surface.
/// If SwiftUI destroys and recreates this, the underlying
/// NSView instance changes.
private struct StableContentView: NSViewRepresentable {
    let stableID: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier(stableID)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
