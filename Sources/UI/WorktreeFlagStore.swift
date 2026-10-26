import Combine
import Foundation
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
        } catch {
            reportDiagnostic("The worktree flag update could not be encoded.")
            throw error
        }
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
}
