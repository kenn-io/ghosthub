import CoreGraphics

/// Shared layout constants for workspace auto-collapse policy.
public enum WorkspaceLayoutConstants {
    public static let minimumMainColumnWidth: CGFloat = 420
    public static let sidePanelDividerWidth: CGFloat = 1
    public static let sidebarAutoCollapseThreshold: CGFloat = 560
}

public enum WorkspaceSidebarWidthPolicy {
    public static let defaultWidth: CGFloat = 320
    public static let minimumWidth: CGFloat = 280
    public static let maximumWidth: CGFloat = 400
    public static let dividerVisualWidth: CGFloat = 3
    public static let dividerHitWidth: CGFloat = 14

    public static func clampedWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    public static func draggedWidth(
        startWidth: CGFloat,
        startX: CGFloat,
        currentX: CGFloat
    ) -> CGFloat {
        clampedWidth(startWidth + currentX - startX)
    }
}

public enum SidebarAutoCollapseAction: Equatable, Sendable {
    case collapse
    case restore
    case noChange
}

public enum SidebarAutoCollapseModel {
    public static func evaluate(
        windowWidth: CGFloat,
        isSidebarVisible: Bool,
        wasAutoCollapsed: Bool
    ) -> SidebarAutoCollapseAction {
        let narrow = windowWidth
            < WorkspaceLayoutConstants.sidebarAutoCollapseThreshold

        if narrow, isSidebarVisible {
            return .collapse
        }
        if !narrow, wasAutoCollapsed {
            return .restore
        }
        return .noChange
    }
}

public enum SidePanelAutoCollapseAction: Equatable, Sendable {
    case collapse
    case restore
    case clearOverride
    case noChange
}

public enum SidePanelAutoCollapseModel {
    static let minimumMainColumnWidth: CGFloat =
        WorkspaceLayoutConstants.minimumMainColumnWidth
    static let dividerWidth: CGFloat =
        WorkspaceLayoutConstants.sidePanelDividerWidth
    /// UX threshold for auto-collapse. The panel hides when
    /// available space drops below this width.
    static let minimumSidePanelColumnWidth: CGFloat = 600

    public static func evaluate(
        windowWidth: CGFloat,
        isSidebarVisible: Bool,
        sidebarWidth: CGFloat = WorkspaceSidebarWidthPolicy.defaultWidth,
        isSidePanelVisible: Bool,
        wasAutoCollapsed: Bool,
        userOverride: Bool
    ) -> SidePanelAutoCollapseAction {
        let sidebar: CGFloat = isSidebarVisible
            ? max(0, sidebarWidth) : 0
        let available = windowWidth
            - sidebar
            - minimumMainColumnWidth
            - dividerWidth
        let tooNarrow = available
            < minimumSidePanelColumnWidth

        if tooNarrow,
           isSidePanelVisible,
           !userOverride {
            return .collapse
        }
        if !tooNarrow, wasAutoCollapsed {
            return .restore
        }
        if !tooNarrow, userOverride {
            return .clearOverride
        }
        return .noChange
    }
}
