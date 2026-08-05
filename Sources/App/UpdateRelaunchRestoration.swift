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
    private enum SceneAssignment {
        case presented(UUID)
        case fallback(UUID)
        case replay(UUID)

        var windowID: UUID {
            switch self {
            case let .presented(windowID), let .fallback(windowID),
                 let .replay(windowID):
                windowID
            }
        }

        var isProvisional: Bool {
            switch self {
            case .fallback, .replay:
                true
            case .presented:
                false
            }
        }
    }

    private struct SceneEntry {
        let registrationOrder: Int
        var assignment: SceneAssignment?
        var restore: (WorkspaceWindowState) -> Void
    }

    private let store: UpdateRelaunchManifestStore
    private var statesByID: [UUID: WorkspaceWindowState]
    private var orderedWindowIDs: [UUID]
    private var replayTargetByRequestID: [UUID: UUID] = [:]
    private var restoringWindowIDs: Set<UUID> = []
    private var sceneEntries: [UUID: SceneEntry] = [:]
    private var nextRegistrationOrder = 0
    private var openWindow: ((WorkspaceWindowState) -> Void)?
    /// AppKit can finish restoring NSWindows before every corresponding
    /// SwiftUI view reaches onAppear and registers its scene here.
    private var expectedNativeSceneCount: Int?
    private var sceneBindingSettlementTask: Task<Void, Never>?
    private var manifestConsumed = false

    init(
        store: UpdateRelaunchManifestStore = .init()
    ) {
        self.store = store
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
        guard !orderedWindowIDs.isEmpty,
              !manifestConsumed || sceneEntries[sceneID] != nil
              || !replayTargetByRequestID.isEmpty
        else { return .ordinary }
        let registrationOrder = sceneEntries[sceneID]?.registrationOrder
            ?? nextRegistrationOrder
        if sceneEntries[sceneID] == nil {
            nextRegistrationOrder += 1
        }
        sceneEntries[sceneID] = SceneEntry(
            registrationOrder: registrationOrder,
            assignment: sceneEntries[sceneID]?.assignment,
            restore: restore
        )
        self.openWindow = openWindow
        return observe(sceneID: sceneID, presented: presented)
    }

    func receivePresentedState(
        sceneID: UUID,
        presented: WorkspaceWindowState?
    ) -> UpdateRelaunchSceneObservation {
        guard !orderedWindowIDs.isEmpty,
              sceneEntries[sceneID] != nil
        else { return .ordinary }
        return observe(sceneID: sceneID, presented: presented)
    }

    func unregisterScene(id sceneID: UUID) {
        sceneEntries.removeValue(forKey: sceneID)
        reconcileIfNativeRestorationFinished()
    }

    @discardableResult
    func nativeWindowRestorationDidFinish(
        expectedSceneCount: Int
    ) -> Bool {
        guard expectedNativeSceneCount == nil else { return false }
        expectedNativeSceneCount = expectedSceneCount
        // A saved updater manifest owns zero-window recovery so it can replay
        // exact workspaces; only an ordinary launch needs a fresh window.
        let needsFreshWindow = expectedSceneCount == 0
            && orderedWindowIDs.isEmpty
        reconcileIfNativeRestorationFinished()
        return needsFreshWindow
    }

    func reconcileIfNativeRestorationFinished() {
        sceneBindingSettlementTask?.cancel()
        sceneBindingSettlementTask = nil
        guard let expectedNativeSceneCount,
              sceneEntries.count >= expectedNativeSceneCount,
              !orderedWindowIDs.isEmpty,
              !manifestConsumed,
              openWindow != nil
        else { return }

        // Registration and an optional binding's decoded value can arrive in
        // separate SwiftUI updates. Require a real quiescence interval and
        // restart it whenever another value arrives. Fallback assignments stay
        // provisional so an even later presented ID can still correct them.
        sceneBindingSettlementTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            self?.sceneBindingSettlementTask = nil
            self?.reconcileAfterSceneBindingsSettled()
        }
    }

    func reconcileAfterSceneBindingsSettled() {
        sceneBindingSettlementTask?.cancel()
        sceneBindingSettlementTask = nil
        guard let expectedNativeSceneCount,
              sceneEntries.count >= expectedNativeSceneCount,
              !orderedWindowIDs.isEmpty,
              !manifestConsumed,
              let openWindow
        else { return }

        let claimedWindowIDs = Set(
            sceneEntries.values.compactMap { $0.assignment?.windowID }
        )
        let scheduledWindowIDs = Set(replayTargetByRequestID.values)
        var missingWindowIDs = orderedWindowIDs.filter {
            !claimedWindowIDs.contains($0)
                && !scheduledWindowIDs.contains($0)
        }
        let availableSceneIDs = sceneEntries
            .filter { $0.value.assignment == nil }
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
            entry.assignment = .fallback(windowID)
            sceneEntries[sceneID] = entry
            restorations.append((entry.restore, state))
        }

        let statesToOpen: [WorkspaceWindowState] = missingWindowIDs
            .map { windowID in
                let request = WorkspaceWindowState.fresh()
                replayTargetByRequestID[request.windowID] = windowID
                return request
            }
        restorations.forEach { restore, state in restore(state) }
        statesToOpen.forEach(openWindow)
    }

    func didBeginRestoring(windowID: UUID) {
        guard statesByID[windowID] != nil else { return }
        restoringWindowIDs.insert(windowID)
        consumeManifestIfComplete()
    }

    private func consumeManifestIfComplete() {
        let assignedWindowIDs = sceneEntries.values.compactMap {
            $0.assignment?.windowID
        }
        guard !manifestConsumed,
              replayTargetByRequestID.isEmpty,
              restoringWindowIDs == Set(statesByID.keys),
              assignedWindowIDs.count == statesByID.count,
              Set(assignedWindowIDs) == Set(statesByID.keys)
        else {
            return
        }
        do {
            try store.clear()
        } catch {
            AppLogger.shared.error(
                "update relaunch: could not consume saved windows: \(error)"
            )
        }
        manifestConsumed = true
        sceneBindingSettlementTask?.cancel()
        sceneBindingSettlementTask = nil
    }

    private func observe(
        sceneID: UUID,
        presented: WorkspaceWindowState?
    ) -> UpdateRelaunchSceneObservation {
        guard var entry = sceneEntries[sceneID] else { return .ordinary }
        if let assignment = entry.assignment {
            let assignedWindowID = assignment.windowID
            guard presented?.windowID != assignedWindowID else {
                return .ordinary
            }
            guard let presented,
                  let saved = statesByID[presented.windowID],
                  assignment.isProvisional
            else {
                return presented == nil
                    ? .ordinary : .waitingForNativeRestoration
            }
            if let otherSceneID = sceneEntries.first(where: {
                $0.key != sceneID
                    && $0.value.assignment?.windowID == saved.windowID
            })?.key,
                var otherEntry = sceneEntries[otherSceneID],
                otherEntry.assignment?.isProvisional == true,
                let previousState = statesByID[assignedWindowID] {
                entry.assignment = .presented(saved.windowID)
                otherEntry.assignment = .fallback(assignedWindowID)
                sceneEntries[sceneID] = entry
                sceneEntries[otherSceneID] = otherEntry
                otherEntry.restore(previousState)
                return .restore(saved)
            }
            guard let requestID = replayTargetByRequestID.first(where: {
                $0.value == saved.windowID
            })?.key,
                let openWindow
            else {
                return .waitingForNativeRestoration
            }
            entry.assignment = .presented(saved.windowID)
            sceneEntries[sceneID] = entry
            replayTargetByRequestID[requestID] = assignedWindowID
            openWindow(.fresh(windowID: requestID))
            return .restore(saved)
        }
        guard let presented else { return .waitingForNativeRestoration }

        if let replayTargetID = replayTargetByRequestID.removeValue(
            forKey: presented.windowID
        ), let replayState = statesByID[replayTargetID] {
            entry.assignment = .replay(replayTargetID)
            sceneEntries[sceneID] = entry
            return .restore(replayState)
        }
        guard let saved = statesByID[presented.windowID]
        else { return .waitingForNativeRestoration }
        guard !sceneEntries.values.contains(where: {
            $0.assignment?.windowID == presented.windowID
        }) else { return .waitingForNativeRestoration }

        entry.assignment = .presented(saved.windowID)
        sceneEntries[sceneID] = entry
        return .restore(saved)
    }

}
