import Foundation

/// Persisted disclosure overrides for the sidebar hierarchy. Hosts and tmux
/// sessions are visible by default, while project groups and individual
/// projects begin collapsed so a large worktree inventory does not hide the
/// rest of the fleet.
struct WorkspaceSidebarDisclosureState: Equatable {
    private(set) var collapsedKeys: Set<String>
    private(set) var expandedKeys: Set<String>

    init(rawValue: String = "") {
        let values = rawValue.split(separator: "\n").map(String.init)
        collapsedKeys = Set(values.compactMap { value in
            if value.hasPrefix("-") {
                return String(value.dropFirst())
            }
            // Preserve compatibility if this state is initialized with the
            // original collapsed-key-only representation.
            return value.hasPrefix("+") ? nil : value
        })
        expandedKeys = Set(values.compactMap { value in
            value.hasPrefix("+") ? String(value.dropFirst()) : nil
        })
    }

    var rawValue: String {
        (expandedKeys.map { "+\($0)" } + collapsedKeys.map { "-\($0)" })
            .sorted()
            .joined(separator: "\n")
    }

    static func migratedRawValue(
        current: String,
        legacyCollapsedKeys: String
    ) -> String {
        guard current.isEmpty, !legacyCollapsedKeys.isEmpty else {
            return current
        }
        return WorkspaceSidebarDisclosureState(
            rawValue: legacyCollapsedKeys
        ).rawValue
    }

    func isExpanded(_ key: String) -> Bool {
        if expandedKeys.contains(key) {
            return true
        }
        if collapsedKeys.contains(key) {
            return false
        }
        return Self.isExpandedByDefault(key)
    }

    mutating func toggle(_ key: String) {
        let expanded = !isExpanded(key)
        collapsedKeys.remove(key)
        expandedKeys.remove(key)
        guard expanded != Self.isExpandedByDefault(key) else { return }
        if expanded {
            expandedKeys.insert(key)
        } else {
            collapsedKeys.insert(key)
        }
    }

    private static func isExpandedByDefault(_ key: String) -> Bool {
        key.hasPrefix("host:")
            || key.hasPrefix("sessions:")
            || key.hasPrefix("herdr-sessions:")
    }

    static func host(_ hostID: UUID) -> String {
        "host:\(hostID.uuidString)"
    }

    static func sessions(_ hostID: UUID) -> String {
        "sessions:\(hostID.uuidString)"
    }

    static func herdrSessions(_ hostID: UUID) -> String {
        "herdr-sessions:\(hostID.uuidString)"
    }

    static func projects(_ hostID: UUID) -> String {
        "projects:\(hostID.uuidString)"
    }

    static func project(_ projectID: UUID) -> String {
        "project:\(projectID.uuidString)"
    }
}
