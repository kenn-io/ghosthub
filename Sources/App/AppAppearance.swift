import GhosthubWorkspace
#if canImport(AppKit)
import AppKit

enum AppAppearance {
    static func resolvedNSAppearanceName(
        for preference: AppearancePreference
    ) -> NSAppearance.Name? {
        switch preference {
        case .system:
            return nil
        case .light:
            return .aqua
        case .dark:
            return .darkAqua
        }
    }

    @MainActor
    static func apply(
        _ preference: AppearancePreference,
        application: NSApplication = .shared
    ) {
        let appearance = resolvedNSAppearanceName(
            for: preference
        ).flatMap(NSAppearance.init(named:))
        application.appearance = appearance
        for window in application.windows {
            window.appearance = appearance
        }
    }
}
#endif
