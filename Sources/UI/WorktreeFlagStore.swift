import Combine
import Foundation
import GhosthubWorkspace
import Observation
import os

@MainActor
public final class WorktreeFlagStore: ObservableObject {
    public static let shared = WorktreeFlagStore()
    static let preferenceKey = "workspaceSidebarWorktreeFlagsV1"
    private static let logger = Logger(subsystem: "com.ghosthub.app", category: "worktree-flags")

    @Published public private(set) var flaggedKeys: Set<WorktreeFlagKey>
    private let defaults: UserDefaults
    private let encodeKeys: (Set<WorktreeFlagKey>) throws -> Data
    private let reportDiagnostic: (String) -> Void
    private var states: [WorktreeFlagKey: StateReference] = [:]

    public convenience init(userDefaults: UserDefaults = .standard) {
        self.init(userDefaults: userDefaults, reportDiagnostic: {
            Self.logger.error("\($0, privacy: .public)")
        })
    }

    init(
        userDefaults: UserDefaults,
        encode: @escaping (Set<WorktreeFlagKey>) throws -> Data = WorktreeFlagStore.encode,
        reportDiagnostic: @escaping (String) -> Void
    ) {
        defaults = userDefaults
        encodeKeys = encode
        self.reportDiagnostic = reportDiagnostic
        flaggedKeys = []
        guard let stored = userDefaults.object(forKey: Self.preferenceKey) else { return }
        guard let data = stored as? Data else {
            reportDiagnostic("Stored worktree flags have an invalid format.")
            return
        }
        do {
            let entries = try JSONDecoder().decode([StoredKey].self, from: data)
            flaggedKeys = Set(entries.compactMap(\.key))
            if entries.contains(where: { $0.key == nil }) {
                reportDiagnostic("Some stored worktree flags have invalid identities.")
            }
        } catch {
            reportDiagnostic("Stored worktree flags could not be decoded.")
        }
    }

    public func isFlagged(_ key: WorktreeFlagKey) -> Bool {
        flaggedKeys.contains(key)
    }

    /// Rows with the same durable key share one narrow observation boundary.
    func state(for key: WorktreeFlagKey?) -> WorktreeFlagState {
        guard let key else { return .unavailable }
        if let state = states[key]?.value {
            return state
        }
        let state = WorktreeFlagState(isFlagged: isFlagged(key))
        states[key] = StateReference(value: state)
        return state
    }

    public func setFlagged(_ flagged: Bool, for key: WorktreeFlagKey) throws {
        guard isFlagged(key) != flagged else { return }
        var updated = flaggedKeys
        if flagged {
            updated.insert(key)
        } else {
            updated.remove(key)
        }
        do {
            let data = try encodeKeys(updated)
            defaults.set(data, forKey: Self.preferenceKey)
            flaggedKeys = updated
            states[key]?.value?.isFlagged = flagged
        } catch {
            reportDiagnostic("The worktree flag update could not be encoded.")
            throw error
        }
    }

    func setFlagged(
        _ flagged: Bool,
        for key: WorktreeFlagKey,
        worktreeID: UUID,
        in snapshot: WorkspaceSnapshot
    ) throws {
        guard WorktreeFlagKey.resolve(worktreeID: worktreeID, in: snapshot) == key else {
            throw WorktreeFlagUpdateError.identityChanged
        }
        try setFlagged(flagged, for: key)
    }

    nonisolated static func encode(_ keys: Set<WorktreeFlagKey>) throws -> Data {
        let sorted = keys.sorted {
            ($0.hostKey, $0.projectKey, $0.generation)
                < ($1.hostKey, $1.projectKey, $1.generation)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(sorted)
    }

    private struct StoredKey: Decodable {
        let key: WorktreeFlagKey?

        init(from decoder: Decoder) throws {
            // Invalid entries are diagnosed once by the containing load.
            key = try? WorktreeFlagKey(from: decoder)
        }
    }

    private struct StateReference {
        weak var value: WorktreeFlagState?
    }
}

@MainActor
@Observable
final class WorktreeFlagState {
    fileprivate static let unavailable = WorktreeFlagState(isFlagged: false)
    fileprivate(set) var isFlagged: Bool

    fileprivate init(isFlagged: Bool) {
        self.isFlagged = isFlagged
    }
}

enum WorktreeFlagUpdateError: LocalizedError {
    case identityChanged

    var errorDescription: String? {
        "This worktree changed. Reopen its actions menu and try again."
    }
}
