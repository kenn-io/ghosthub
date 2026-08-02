import SwiftUI

/// App-level registry that tracks all active `WorkspaceSceneModel`
/// instances so quit-policy and other app-wide queries can
/// aggregate across every open window.
@MainActor
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()

    private struct Entry {
        let model: WorkspaceSceneModel
        let registrationOrder: Int
        let captureRestorationState: () -> WorkspaceWindowState

        init(
            model: WorkspaceSceneModel,
            registrationOrder: Int,
            captureRestorationState: @escaping () -> WorkspaceWindowState
        ) {
            self.model = model
            self.registrationOrder = registrationOrder
            self.captureRestorationState = captureRestorationState
        }
    }

    private var sceneEntries: [ObjectIdentifier: Entry] = [:]
    private var nextRegistrationOrder = 0

    func register(
        _ model: WorkspaceSceneModel,
        captureRestorationState: @escaping () -> WorkspaceWindowState
    ) {
        let identifier = ObjectIdentifier(model)
        let registrationOrder = sceneEntries[identifier]?.registrationOrder
            ?? nextRegistrationOrder
        if sceneEntries[identifier] == nil {
            nextRegistrationOrder += 1
        }
        sceneEntries[identifier] = Entry(
            model: model,
            registrationOrder: registrationOrder,
            captureRestorationState: captureRestorationState
        )
    }

    func unregister(_ model: WorkspaceSceneModel) {
        sceneEntries.removeValue(forKey: ObjectIdentifier(model))
    }

    func captureRestorationStates() -> [WorkspaceWindowState] {
        sceneEntries.values
            .sorted { $0.registrationOrder < $1.registrationOrder }
            .map { $0.captureRestorationState() }
    }

    var totalOpenTerminalSurfaceCount: Int {
        sceneEntries.values.reduce(0) { $0 + $1.model.openTerminalSurfaceCount }
    }

    var workspaceWindowCount: Int {
        sceneEntries.count
    }
}
