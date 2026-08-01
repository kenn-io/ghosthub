import AppKit
import SwiftUI
import Testing
@testable import GhosthubUI

@MainActor
@Suite("Web preview workspace layout")
struct WebPreviewWorkspaceLayoutTests {
    @Test("responsive modes preserve the terminal view instance")
    func responsiveModesPreserveTerminalIdentity() {
        let environment = WebPreviewLayoutTestEnvironment()
        let originalTerminal = environment.terminalView()

        #expect(originalTerminal != nil)

        environment.mode = .split
        #expect(environment.terminalView() === originalTerminal)

        environment.mode = .previewOnly
        #expect(environment.terminalView() === originalTerminal)

        environment.mode = .terminalOnly
        #expect(environment.terminalView() === originalTerminal)
    }
}

@MainActor
private final class WebPreviewLayoutTestEnvironment {
    var mode: WebPreviewLayoutMode = .terminalOnly {
        didSet { update() }
    }

    private let identifier = "web-preview-stable-terminal"
    private let window: NSWindow
    private let hostingView: NSHostingView<AnyView>
    private var previewWidth = WebPreviewLayoutPolicy.defaultPreviewWidth

    init() {
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        update()
    }

    func terminalView() -> NSView? {
        descendants(of: hostingView).first {
            $0.accessibilityIdentifier() == identifier
        }
    }

    private func update() {
        hostingView.rootView = AnyView(
            WebPreviewWorkspaceLayout(
                mode: mode,
                previewWidth: Binding(
                    get: { self.previewWidth },
                    set: { self.previewWidth = $0 }
                ),
                terminal: AnyView(StableTerminalView(identifier: identifier)),
                preview: AnyView(Color.blue)
            )
        )
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

private struct StableTerminalView: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
