import Foundation

public enum TerminalTheme: String, CaseIterable, Identifiable, Sendable {
    case followConfig
    case pro
    case homebrew
    case clearDark
    case clearLight
    case novel
    case ocean

    public var id: Self { self }

    public var title: String {
        switch self {
        case .followConfig:
            return "Follow ghostty.conf"
        case .pro:
            return "Pro"
        case .homebrew:
            return "Homebrew"
        case .clearDark:
            return "Clear Dark"
        case .clearLight:
            return "Clear Light"
        case .novel:
            return "Novel"
        case .ocean:
            return "Ocean"
        }
    }

    public var summary: String {
        switch self {
        case .followConfig:
            return "Do not apply a Ghosthub theme overlay."
        case .pro:
            return "Monaco-inspired black glass with bright monochrome text."
        case .homebrew:
            return "Classic green-on-black Homebrew look."
        case .clearDark:
            return "Subtle blue-black translucent palette."
        case .clearLight:
            return "Airy light palette with steel-blue accents."
        case .novel:
            return "Paper-like sepia palette for long reading."
        case .ocean:
            return "Bright blue background with white text."
        }
    }

    public var spec: TerminalThemeSpec? {
        switch self {
        case .followConfig:
            return nil
        case .pro:
            return TerminalThemeSpec(
                background: .init(0.0000, 0.0000, 0.0000, 0.8500),
                foreground: .init(0.9582, 0.9582, 0.9582, 1.0000),
                emphasis: .init(1.0000, 1.0000, 1.0000, 1.0000),
                cursor: .init(0.3752, 0.3752, 0.3752, 1.0000),
                selection: .init(0.3225, 0.3225, 0.3225, 1.0000)
            )
        case .homebrew:
            return TerminalThemeSpec(
                background: .init(0.0000, 0.0000, 0.0000, 0.9000),
                foreground: .init(0.1569, 0.9961, 0.0784, 1.0000),
                emphasis: .init(0.0000, 0.9768, 0.0000, 1.0000),
                cursor: .init(0.2196, 0.9961, 0.1529, 1.0000),
                selection: .init(0.0451, 0.1818, 0.9319, 0.6500)
            )
        case .clearDark:
            return TerminalThemeSpec(
                background: .init(0.1298, 0.1534, 0.2028, 0.9500),
                foreground: .init(0.9016, 0.9016, 0.9016, 1.0000),
                emphasis: .init(0.9430, 0.9430, 0.9430, 1.0000),
                cursor: nil,
                selection: .init(0.2009, 0.3047, 0.3700, 1.0000)
            )
        case .clearLight:
            return TerminalThemeSpec(
                background: .init(1.0000, 1.0000, 1.0000, 0.9300),
                foreground: .init(0.2294, 0.2825, 0.3175, 1.0000),
                emphasis: .init(0.1903, 0.2361, 0.2663, 1.0000),
                cursor: .init(0.5700, 0.5700, 0.5700, 1.0000),
                selection: .init(0.8968, 0.9266, 0.9471, 1.0000)
            )
        case .novel:
            return TerminalThemeSpec(
                background: .init(0.8750, 0.8580, 0.7656, 1.0000),
                foreground: .init(0.3013, 0.1835, 0.1769, 1.0000),
                emphasis: .init(0.5780, 0.2288, 0.1288, 1.0000),
                cursor: .init(0.2275, 0.1373, 0.1333, 0.6500),
                selection: .init(0.5285, 0.5219, 0.3882, 0.7600)
            )
        case .ocean:
            return TerminalThemeSpec(
                background: .init(0.1694, 0.4010, 0.7870, 1.0000),
                foreground: .init(1.0000, 1.0000, 1.0000, 1.0000),
                emphasis: .init(1.0000, 1.0000, 1.0000, 1.0000),
                cursor: nil,
                selection: .init(0.1595, 0.5264, 1.0000, 1.0000)
            )
        }
    }
}

public struct TerminalAppearancePreferences: Equatable, Sendable {
    public var theme: TerminalTheme
    public var appliesThemeToTmuxSessions: Bool
    public var usesCustomFont: Bool
    public var fontFamily: String
    public var fontSize: Double

    public init(
        theme: TerminalTheme,
        appliesThemeToTmuxSessions: Bool,
        usesCustomFont: Bool,
        fontFamily: String,
        fontSize: Double
    ) {
        self.theme = theme
        self.appliesThemeToTmuxSessions = appliesThemeToTmuxSessions
        self.usesCustomFont = usesCustomFont
        self.fontFamily = fontFamily
        self.fontSize = fontSize
    }
}

public struct TerminalThemeSpec: Equatable, Sendable {
    public let background: TerminalColor
    public let foreground: TerminalColor
    public let emphasis: TerminalColor
    public let cursor: TerminalColor?
    public let selection: TerminalColor?

    public var cursorColor: TerminalColor {
        cursor ?? emphasis
    }
}

public struct TerminalColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var hexRGB: String {
        let r = Int((red * 255.0).rounded())
        let g = Int((green * 255.0).rounded())
        let b = Int((blue * 255.0).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
