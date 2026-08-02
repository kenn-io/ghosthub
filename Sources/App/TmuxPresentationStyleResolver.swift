import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubTmux

enum TmuxPresentationStyleResolver {
    static func resolve(
        preferences: TerminalAppearancePreferences,
        resolvedColors: TerminalResolvedColors?
    ) -> TmuxPresentationStyle? {
        if let spec = preferences.theme.spec {
            return TmuxPresentationStyle(
                foreground: spec.foreground.hexRGB,
                background: spec.background.hexRGB
            )
        }
        guard let resolvedColors else { return nil }
        return TmuxPresentationStyle(
            foreground: resolvedColors.foreground,
            background: resolvedColors.background
        )
    }
}
