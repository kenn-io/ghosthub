public enum TerminalBackgroundBlur: Equatable, Sendable {
    case disabled
    case radius(Int)
    /// macOS 26 glass styles (config c-values -1/-2). The window still goes
    /// transparent, but the libghostty radius-blur call is skipped, matching
    /// Ghostty.app: the embedded blur function would pass the negative glass
    /// value straight to CGSSetWindowBackgroundBlurRadius. Like Ghostty.app,
    /// a radius installed by an earlier config survives a live reload into a
    /// glass style; Ghosthub does not render glass and cannot clear the
    /// radius without calling private CGS API directly.
    case systemGlass
}

/// Window/chrome transparency derived from the loaded libghostty config.
/// libghostty remains authoritative for parsing; this type only interprets
/// the values `ghostty_config_get` returns.
public struct TerminalBackgroundAppearance: Equatable, Sendable {
    public let opacity: Double
    public let blur: TerminalBackgroundBlur

    public static let opaque = Self(
        opacity: 1.0, blurCValue: 0, increasedContrast: false
    )

    public init(
        opacity: Double,
        blurCValue: Int16,
        increasedContrast: Bool
    ) {
        if increasedContrast {
            self.opacity = 1.0
            blur = .disabled
            return
        }
        self.opacity = min(max(opacity, 0.0), 1.0)
        switch blurCValue {
        case ..<0:
            blur = .systemGlass
        case 0:
            blur = .disabled
        default:
            blur = .radius(Int(blurCValue))
        }
    }

    public var isTransparent: Bool { opacity < 1.0 }

    /// Whether the applier should hand this window to libghostty's
    /// background-blur call. True for `.disabled` too: calling with radius 0
    /// clears blur left over from a previous transparent configuration.
    public var appliesWindowBlur: Bool {
        guard isTransparent else { return false }
        switch blur {
        case .disabled, .radius:
            return true
        case .systemGlass:
            return false
        }
    }
}
