import SwiftUI

/// App-level registry that tracks all active `WorkspaceSceneModel`
/// instances so quit-policy and other app-wide queries can
/// aggregate across every open window.
@MainActor
final class WindowRegistry: ObservableObject {
    static let shared = WindowRegistry()

    private(set) var sceneModels: [ObjectIdentifier: WorkspaceSceneModel] = [:]

    func register(_ model: WorkspaceSceneModel) {
        sceneModels[ObjectIdentifier(model)] = model
    }

    func unregister(_ model: WorkspaceSceneModel) {
        sceneModels.removeValue(forKey: ObjectIdentifier(model))
    }

    var totalOpenTerminalSurfaceCount: Int {
        sceneModels.values.reduce(0) { $0 + $1.openTerminalSurfaceCount }
    }
}
