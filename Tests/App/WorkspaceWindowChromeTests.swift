import AppKit
import GhosthubTerminalSupport
import Testing
@testable import GhosthubApp

@Suite("WorkspaceWindowChrome appearance")
@MainActor
struct WorkspaceWindowChromeTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
    }

    private func resolvedAlpha(of window: NSWindow) -> CGFloat? {
        window.backgroundColor.usingColorSpace(.sRGB)?.alphaComponent
    }

    @Test("transparent appearance unsets window opacity")
    func transparentWindow() {
        let window = makeWindow()
        var blurredWindows: [NSWindow] = []
        WorkspaceWindowChrome.apply(
            to: window,
            appearance: TerminalBackgroundAppearance(
                opacity: 0.8, blurCValue: 20, increasedContrast: false
            ),
            applyBlur: { blurredWindows.append($0) }
        )
        #expect(!window.isOpaque)
        #expect((resolvedAlpha(of: window) ?? 1) < 0.01)
        #expect(window.hasShadow)
        #expect(blurredWindows.count == 1)
    }

    @Test("opaque appearance restores current chrome")
    func opaqueWindow() {
        let window = makeWindow()
        var blurCalls = 0
        WorkspaceWindowChrome.apply(
            to: window,
            appearance: TerminalBackgroundAppearance(
                opacity: 0.8, blurCValue: 20, increasedContrast: false
            ),
            applyBlur: { _ in blurCalls += 1 }
        )
        WorkspaceWindowChrome.apply(
            to: window,
            appearance: .opaque,
            applyBlur: { _ in blurCalls += 1 }
        )
        #expect(window.isOpaque)
        #expect(resolvedAlpha(of: window) == 1)
        #expect(blurCalls == 1)
    }

    @Test("glass blur styles skip the blur call but stay transparent")
    func glassSkipsBlur() {
        let window = makeWindow()
        var blurCalls = 0
        WorkspaceWindowChrome.apply(
            to: window,
            appearance: TerminalBackgroundAppearance(
                opacity: 0.8, blurCValue: -1, increasedContrast: false
            ),
            applyBlur: { _ in blurCalls += 1 }
        )
        #expect(!window.isOpaque)
        #expect(blurCalls == 0)
    }
}
