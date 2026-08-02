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

@MainActor
final class UpdateRelaunchRestorer {
    private let store: UpdateRelaunchManifestStore
    private var statesByID: [UUID: WorkspaceWindowState]
    private var orderedWindowIDs: [UUID]
    private var scheduledWindowIDs: Set<UUID> = []
    private var restoringWindowIDs: Set<UUID> = []
    private var replaysMissingWindows = false

    init(store: UpdateRelaunchManifestStore = .init()) {
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

    func stateForAppearance(
        presented: WorkspaceWindowState?
    ) -> WorkspaceWindowState? {
        guard !orderedWindowIDs.isEmpty else { return presented }

        if let presented,
           let saved = statesByID[presented.windowID] {
            return saved
        }

        guard let windowID = orderedWindowIDs.first(where: {
            !scheduledWindowIDs.contains($0)
                && !restoringWindowIDs.contains($0)
        })
        else { return presented }
        replaysMissingWindows = true
        scheduledWindowIDs.insert(windowID)
        return statesByID[windowID]
    }

    func containsSavedState(windowID: UUID) -> Bool {
        statesByID[windowID] != nil
    }

    func takeStatesToOpen() -> [WorkspaceWindowState] {
        guard replaysMissingWindows else { return [] }
        return orderedWindowIDs.compactMap { windowID ->
            WorkspaceWindowState? in
            guard !scheduledWindowIDs.contains(windowID),
                  !restoringWindowIDs.contains(windowID),
                  let state = statesByID[windowID]
            else { return nil }
            scheduledWindowIDs.insert(windowID)
            return state
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
        replaysMissingWindows = false
    }
}
