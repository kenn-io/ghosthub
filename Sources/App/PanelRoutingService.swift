import Foundation
import OSLog

/// Persists the visibility of the host-scoped console panel.
///
/// The panel is independent of workspace navigation. It must not carry web
/// routes, project mutations, or session authority.
@MainActor
final class PanelRoutingService: ObservableObject {
    @Published private(set) var isSidePanelVisible = false

    private let preferenceStore: PanelPreferenceStore

    init(preferenceStore: PanelPreferenceStore) {
        self.preferenceStore = preferenceStore
        isSidePanelVisible =
            (try? preferenceStore.loadVisibility()) ?? false
    }

    func setSidePanelVisible(_ isVisible: Bool) {
        guard isSidePanelVisible != isVisible else { return }
        isSidePanelVisible = isVisible
        do {
            try preferenceStore.persistVisibility(isVisible)
        } catch {
            AppLogger.shared.error(
                "failed to persist console panel visibility: \(error)"
            )
        }
    }
}
