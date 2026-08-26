import AppKit
import GhosthubTerminalSupport
import SwiftUI
import Testing
@testable import GhosthubApp

@Suite("TerminalSurfaceBackdrop")
@MainActor
struct TerminalSurfaceBackdropTests {
    @Test("clear under a transparent appearance")
    func transparentBackdrop() {
        let appearance = TerminalBackgroundAppearance(
            opacity: 0.8, blurCValue: 0, increasedContrast: false
        )
        #expect(TerminalSurfaceBackdrop.color(for: appearance) == .clear)
    }

    @Test("system text background when opaque")
    func opaqueBackdrop() {
        #expect(
            TerminalSurfaceBackdrop.color(for: .opaque)
                == Color(nsColor: .textBackgroundColor)
        )
    }
}
