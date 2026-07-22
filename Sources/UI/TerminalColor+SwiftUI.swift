import SwiftUI
import GhosthubSettings

extension TerminalColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
