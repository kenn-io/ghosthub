import AppKit
import SwiftUI

// MARK: - Appearance-aware surface colors

//
// macOS system colors (windowBackgroundColor, controlBackgroundColor)
// are pure white in light mode which is harsh. These provide softer
// titanium-toned alternatives that feel premium in both modes.

private func dynamicColor(
    light: NSColor,
    dark: NSColor,
    lightHighContrast: NSColor? = nil,
    darkHighContrast: NSColor? = nil
) -> Color {
    Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua,
                .darkAqua,
                .aqua,
            ])
            switch match {
            case .accessibilityHighContrastDarkAqua:
                return darkHighContrast ?? dark
            case .accessibilityHighContrastAqua:
                return lightHighContrast ?? light
            case .darkAqua:
                return dark
            default:
                return light
            }
        }
    ))
}

/// Main pane/window background — replaces windowBackgroundColor.
/// Delegates to `WorkspaceSurfaceColor` so native workspace surfaces agree.
public let paneFill = WorkspaceSurfaceColor.color

/// Toolbar / header background — replaces controlBackgroundColor.
/// Light: slightly lighter titanium. Dark: standard control bg.
/// High-contrast: falls back to semantic system colors.
let toolbarFill = dynamicColor(
    light: NSColor(
        calibratedWhite: 0.95, alpha: 1.0
    ),
    dark: NSColor.controlBackgroundColor,
    lightHighContrast: NSColor.controlBackgroundColor,
    darkHighContrast: NSColor.controlBackgroundColor
)

/// Canonical workspace surface color shared by native chrome and terminals.
public enum WorkspaceSurfaceColor {
    public static let nsColor: NSColor = .init(
        name: nil,
        dynamicProvider: { appearance in
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua,
                .darkAqua,
                .aqua,
            ])
            switch match {
            case .accessibilityHighContrastDarkAqua:
                // Pure black under high-contrast dark for
                // maximum contrast against text and chrome.
                return NSColor.black
            case .accessibilityHighContrastAqua:
                // Pure white under high-contrast light, same
                // intent.
                return NSColor.white
            case .darkAqua:
                return NSColor(
                    srgbRed: 0x0c / 255.0,
                    green: 0x0c / 255.0,
                    blue: 0x14 / 255.0,
                    alpha: 1.0
                )
            default:
                return NSColor(
                    srgbRed: 0xf8 / 255.0,
                    green: 0xf8 / 255.0,
                    blue: 0xfa / 255.0,
                    alpha: 1.0
                )
            }
        }
    )

    public static let color: Color = .init(nsColor: nsColor)

    public static func hexString(
        for appearance: NSAppearance
    ) -> String {
        var r = 0, g = 0, b = 0
        appearance.performAsCurrentDrawingAppearance {
            let resolved = nsColor
                .usingColorSpace(.sRGB) ?? nsColor
            r = Int(round(resolved.redComponent * 255))
            g = Int(round(resolved.greenComponent * 255))
            b = Int(round(resolved.blueComponent * 255))
        }
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
