import GhosthubTerminalSupport
import SwiftUI

enum TerminalSurfaceBackdrop {
    /// Fills the cell-grid letterbox gap around a terminal surface. Clear
    /// when transparent: the surface draws its own alpha background, and any
    /// paint behind it would defeat the configured opacity.
    static func color(
        for appearance: TerminalBackgroundAppearance
    ) -> Color {
        appearance.isTransparent
            ? .clear
            : Color(nsColor: .textBackgroundColor)
    }
}
