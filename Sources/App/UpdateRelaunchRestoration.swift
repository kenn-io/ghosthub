import Foundation
import GhosthubWorkspace

struct UpdateRelaunchManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var windows: [WorkspaceWindowState]

    init(windows: [WorkspaceWindowState]) {
        schemaVersion = Self.currentSchemaVersion
        self.windows = windows
    }
}

struct UpdateRelaunchManifestStore {
    enum StoreError: Error {
        case unsupportedSchema(Int)
    }

    let fileURL: URL
    private let fileManager: FileManager

    init(
        fileURL: URL = StateHome.resolved()
            .appendingPathComponent("update-relaunch.json"),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func save(_ states: [WorkspaceWindowState]) throws {
        guard !states.isEmpty else {
            try clear()
            return
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            UpdateRelaunchManifest(windows: states)
        )
        try data.write(to: fileURL, options: .atomic)
    }

    func load() throws -> [WorkspaceWindowState]? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let manifest = try JSONDecoder().decode(
            UpdateRelaunchManifest.self,
            from: Data(contentsOf: fileURL)
        )
        guard manifest.schemaVersion
            == UpdateRelaunchManifest.currentSchemaVersion
        else {
            throw StoreError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest.windows
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        try fileManager.removeItem(at: fileURL)
    }
}

enum UpdateRelaunchSceneObservation: Equatable {
    case ordinary
    case waitingForNativeRestoration
    case restore(WorkspaceWindowState)
}

@MainActor
final class UpdateRelaunchRestorer {
    private struct SceneEntry {
        let registrationOrder: Int
        var assignedWindowID: UUID?
        var restore: (WorkspaceWindowState) -> Void
    }

    private let store: UpdateRelaunchManifestStore
    private let reconciliationDelayNanoseconds: UInt64?
    private var statesByID: [UUID: WorkspaceWindowState]
    private var orderedWindowIDs: [UUID]
    private var scheduledWindowIDs: Set<UUID> = []
    private var restoringWindowIDs: Set<UUID> = []
    private var sceneEntries: [UUID: SceneEntry] = [:]
    private var nextRegistrationOrder = 0
    private var openWindow: ((WorkspaceWindowState) -> Void)?
    private var reconciliationTask: Task<Void, Never>?

    init(
        store: UpdateRelaunchManifestStore = .init(),
        // SwiftUI can publish decoded scene values after onAppear. Restarting
        // this short quiet period on every scene update lets native claims
        // arrive before Ghosthub assigns or opens the remaining manifest IDs.
        reconciliationDelayNanoseconds: UInt64? = 250_000_000
    ) {
        self.store = store
        self.reconciliationDelayNanoseconds =
            reconciliationDelayNanoseconds
        do {
            let states = try store.load() ?? []
            orderedWindowIDs = states.map(\.windowID)
            statesByID = Dictionary(
                states.map { ($0.windowID, $0) },
                uniquingKeysWith: { saved, _ in saved }
            )
            orderedWindowIDs = orderedWindowIDs.reduce(into: []) {
                uniqueIDs, windowID in
                guard !uniqueIDs.contains(windowID) else { return }
                uniqueIDs.append(windowID)
            }
        } catch {
            orderedWindowIDs = []
            statesByID = [:]
            AppLogger.shared.error(
                "update relaunch: could not load saved windows: \(error)"
            )
        }
    }

    func registerScene(
        id sceneID: UUID,
        presented: WorkspaceWindowState?,
        restore: @escaping (WorkspaceWindowState) -> Void,
        openWindow: @escaping (WorkspaceWindowState) -> Void
    ) -> UpdateRelaunchSceneObservation {
        guard !orderedWindowIDs.isEmpty else { return .ordinary }
        let registrationOrder = sceneEntries[sceneID]?.registrationOrder
            ?? nextRegistrationOrder
        if sceneEntries[sceneID] == nil {
            nextRegistrationOrder += 1
        }
        sceneEntries[sceneID] = SceneEntry(
            registrationOrder: registrationOrder,
            assignedWindowID: sceneEntries[sceneID]?.assignedWindowID,
            restore: restore
        )
        self.openWindow = openWindow
        let observation = observe(sceneID: sceneID, presented: presented)
        scheduleReconciliation()
        return observation
    }

    func receivePresentedState(
        sceneID: UUID,
        presented: WorkspaceWindowState?
    ) -> UpdateRelaunchSceneObservation {
        guard !orderedWindowIDs.isEmpty,
              sceneEntries[sceneID] != nil
        else { return .ordinary }
        let observation = observe(sceneID: sceneID, presented: presented)
        scheduleReconciliation()
        return observation
    }

    func unregisterScene(id sceneID: UUID) {
        sceneEntries.removeValue(forKey: sceneID)
        scheduleReconciliation()
    }

    func reconcileAfterNativeRestorationSettled() {
        reconciliationTask?.cancel()
        reconciliationTask = nil
        guard !orderedWindowIDs.isEmpty else { return }

        let claimedWindowIDs = Set(
            sceneEntries.values.compactMap(\.assignedWindowID)
        )
        var missingWindowIDs = orderedWindowIDs.filter {
            !claimedWindowIDs.contains($0)
                && !scheduledWindowIDs.contains($0)
                && !restoringWindowIDs.contains($0)
        }
        let availableSceneIDs = sceneEntries
            .filter { $0.value.assignedWindowID == nil }
            .sorted {
                $0.value.registrationOrder < $1.value.registrationOrder
            }
            .map(\.key)

        var restorations: [(
            (WorkspaceWindowState) -> Void,
            WorkspaceWindowState
        )] = []
        for sceneID in availableSceneIDs {
            guard let windowID = missingWindowIDs.first,
                  let state = statesByID[windowID],
                  var entry = sceneEntries[sceneID]
            else { break }
            missingWindowIDs.removeFirst()
            entry.assignedWindowID = windowID
            sceneEntries[sceneID] = entry
            restorations.append((entry.restore, state))
        }

        let statesToOpen: [WorkspaceWindowState] = missingWindowIDs
            .compactMap { windowID in
                guard let state = statesByID[windowID] else { return nil }
                scheduledWindowIDs.insert(windowID)
                return state
            }
        restorations.forEach { restore, state in restore(state) }
        if let openWindow {
            statesToOpen.forEach(openWindow)
        }
    }

    func didBeginRestoring(windowID: UUID) {
        guard statesByID[windowID] != nil else { return }
        restoringWindowIDs.insert(windowID)
        guard restoringWindowIDs.count == statesByID.count else {
            return
        }
        do {
            try store.clear()
        } catch {
            AppLogger.shared.error(
                "update relaunch: could not consume saved windows: \(error)"
            )
        }
        orderedWindowIDs = []
        statesByID = [:]
        scheduledWindowIDs = []
        restoringWindowIDs = []
        sceneEntries = [:]
        openWindow = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
    }

    private func observe(
        sceneID: UUID,
        presented: WorkspaceWindowState?
    ) -> UpdateRelaunchSceneObservation {
        guard var entry = sceneEntries[sceneID] else { return .ordinary }
        if let assignedWindowID = entry.assignedWindowID {
            guard presented?.windowID != assignedWindowID else {
                return .ordinary
            }
            return presented == nil
                ? .ordinary : .waitingForNativeRestoration
        }
        guard let presented,
              let saved = statesByID[presented.windowID],
              !sceneEntries.values.contains(where: {
                  $0.assignedWindowID == presented.windowID
              })
        else { return .waitingForNativeRestoration }

        entry.assignedWindowID = saved.windowID
        sceneEntries[sceneID] = entry
        scheduledWindowIDs.remove(saved.windowID)
        return .restore(saved)
    }

    private func scheduleReconciliation() {
        guard let reconciliationDelayNanoseconds,
              !orderedWindowIDs.isEmpty
        else { return }
        reconciliationTask?.cancel()
        reconciliationTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: reconciliationDelayNanoseconds
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.reconcileAfterNativeRestorationSettled()
        }
    }
}
