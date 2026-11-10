/// Orders the session list under each sidebar host.
public enum SidebarSessionSort: String, CaseIterable, Identifiable, Sendable {
    /// One drag order across every backend.
    case manual
    case name
    /// tmux, Zellij, Herdr terminals, then Herdr TUI sessions.
    case backend
    /// Agents waiting on the user first, then working, then done.
    case attention

    public var id: Self { self }

    public var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .backend: "Backend"
        case .attention: "Needs Attention"
        }
    }
}

/// How a session row names its multiplexer.
public enum SidebarBackendLabelStyle: String, CaseIterable, Identifiable, Sendable {
    case chip
    case text
    case dot

    public var id: Self { self }

    public var title: String {
        switch self {
        case .chip: "Chip"
        case .text: "Text"
        case .dot: "Dot"
        }
    }
}

public enum SidebarRowHeight: String, CaseIterable, Identifiable, Sendable {
    case regular
    case compact

    public var id: Self { self }

    public var title: String {
        switch self {
        case .regular: "Regular"
        case .compact: "Compact"
        }
    }
}

public struct SidebarPreferences: Equatable, Sendable {
    public var sessionSort: SidebarSessionSort
    public var backendLabelStyle: SidebarBackendLabelStyle
    public var rowHeight: SidebarRowHeight

    public init(
        sessionSort: SidebarSessionSort = .manual,
        backendLabelStyle: SidebarBackendLabelStyle = .chip,
        rowHeight: SidebarRowHeight = .regular
    ) {
        self.sessionSort = sessionSort
        self.backendLabelStyle = backendLabelStyle
        self.rowHeight = rowHeight
    }
}
