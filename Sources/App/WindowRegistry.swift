import SwiftUI

/// App-level registry that tracks all active `WorkspaceSceneModel`
/// instances so quit-policy and other app-wide queries can
/// aggregate across every open window.
@MainActor
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()

    private struct Entry {
        let model: WorkspaceSceneModel
        let refreshRestorationState: () -> Void

        init(
            model: WorkspaceSceneModel,
            refreshRestorationState: @escaping () -> Void
        ) {
            self.model = model
            self.refreshRestorationState = refreshRestorationState
        }
    }

    private var sceneEntries: [ObjectIdentifier: Entry] = [:]

    func register(
        _ model: WorkspaceSceneModel,
        refreshRestorationState: @escaping () -> Void
    ) {
        sceneEntries[ObjectIdentifier(model)] = Entry(
            model: model,
            refreshRestorationState: refreshRestorationState
        )
    }

    func unregister(_ model: WorkspaceSceneModel) {
        sceneEntries.removeValue(forKey: ObjectIdentifier(model))
    }

    func refreshRestorationStates() {
        sceneEntries.values.forEach { $0.refreshRestorationState() }
    }

    var totalOpenTerminalSurfaceCount: Int {
        sceneEntries.values.reduce(0) { $0 + $1.model.openTerminalSurfaceCount }
    }

    var workspaceWindowCount: Int {
        sceneEntries.count
    }
}
