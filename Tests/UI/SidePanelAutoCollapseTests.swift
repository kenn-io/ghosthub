import Foundation
import Testing
@testable import GhosthubUI

struct SidebarAutoCollapseTests {
    @Test("sidebar auto-collapses below threshold")
    func autoCollapsesBelowThreshold() {
        let result = SidebarAutoCollapseModel.evaluate(
            windowWidth: WorkspaceLayoutConstants
                .sidebarAutoCollapseThreshold - 1,
            isSidebarVisible: true,
            wasAutoCollapsed: false
        )
        #expect(result == .collapse)
    }

    @Test("sidebar auto-restores after an automatic collapse")
    func autoRestoresWhenWide() {
        let result = SidebarAutoCollapseModel.evaluate(
            windowWidth: WorkspaceLayoutConstants
                .sidebarAutoCollapseThreshold,
            isSidebarVisible: false,
            wasAutoCollapsed: true
        )
        #expect(result == .restore)
    }

    @Test("sidebar leaves manually hidden state alone")
    func leavesManualHiddenStateAlone() {
        let result = SidebarAutoCollapseModel.evaluate(
            windowWidth: WorkspaceLayoutConstants
                .sidebarAutoCollapseThreshold - 1,
            isSidebarVisible: false,
            wasAutoCollapsed: false
        )
        #expect(result == .noChange)
    }
}

struct SidePanelAutoCollapseTests {
    static let sidebarWidth: CGFloat =
        WorkspaceSidebarWidthPolicy.defaultWidth
    static let mainColumnMin: CGFloat =
        WorkspaceLayoutConstants.minimumMainColumnWidth
    static let divider: CGFloat =
        WorkspaceLayoutConstants.sidePanelDividerWidth
    static let panelMin: CGFloat =
        SidePanelAutoCollapseModel.minimumSidePanelColumnWidth

    /// Minimum window to fit sidebar + main + divider + panel
    static let fullLayoutMin: CGFloat =
        sidebarWidth + mainColumnMin + divider + panelMin

    @Test("panel auto-collapses when window too narrow with sidebar")
    func autoCollapsesWithSidebar() {
        // Window at 960 with sidebar:
        // available = 960 - 320 - 420 - 1 = 219 < 600
        let result = SidePanelAutoCollapseModel.evaluate(
            windowWidth: 960,
            isSidebarVisible: true,
            isSidePanelVisible: true,
            wasAutoCollapsed: false,
            userOverride: false
        )
        #expect(result == .collapse)
    }

    @Test("panel stays visible when window is wide enough")
    func staysVisibleWhenWide() {
        let result = SidePanelAutoCollapseModel.evaluate(
            windowWidth: Self.fullLayoutMin + 10,
            isSidebarVisible: true,
            isSidePanelVisible: true,
            wasAutoCollapsed: false,
            userOverride: false
        )
        #expect(result == .noChange)
    }

    @Test("panel auto-restores when window grows")
    func autoRestoresWhenGrows() {
        let result = SidePanelAutoCollapseModel.evaluate(
            windowWidth: Self.fullLayoutMin + 10,
            isSidebarVisible: true,
            isSidePanelVisible: false,
            wasAutoCollapsed: true,
            userOverride: false
        )
        #expect(result == .restore)
    }

    @Test("panel does not auto-collapse when user override is set")
    func respectsUserOverride() {
        let result = SidePanelAutoCollapseModel.evaluate(
            windowWidth: 960,
            isSidebarVisible: true,
            isSidePanelVisible: true,
            wasAutoCollapsed: false,
            userOverride: true
        )
        #expect(result == .noChange)
    }

    @Test("panel has more room without sidebar")
    func moreRoomWithoutSidebar() {
        // Without sidebar: available = 1100 - 0 - 420 - 1 = 679 > 600
        let result = SidePanelAutoCollapseModel.evaluate(
            windowWidth: 1100,
            isSidebarVisible: false,
            isSidePanelVisible: true,
            wasAutoCollapsed: false,
            userOverride: false
        )
        #expect(result == .noChange)
    }

    @Test("panel auto-collapse accounts for resized sidebar width")
    func accountsForResizedSidebarWidth() {
        let result = SidePanelAutoCollapseModel.evaluate(
            windowWidth: Self.fullLayoutMin + 60,
            isSidebarVisible: true,
            sidebarWidth: WorkspaceSidebarWidthPolicy.maximumWidth,
            isSidePanelVisible: true,
            wasAutoCollapsed: false,
            userOverride: false
        )
        #expect(result == .collapse)
    }

    @Test("user override resets when window grows above threshold")
    func userOverrideResetsWhenGrows() {
        let result = SidePanelAutoCollapseModel.evaluate(
            windowWidth: Self.fullLayoutMin + 10,
            isSidebarVisible: true,
            isSidePanelVisible: true,
            wasAutoCollapsed: false,
            userOverride: true
        )
        #expect(result == .clearOverride)
    }

    @Test("no action when panel already hidden and not auto-collapsed")
    func noActionWhenManuallyHidden() {
        let result = SidePanelAutoCollapseModel.evaluate(
            windowWidth: 960,
            isSidebarVisible: true,
            isSidePanelVisible: false,
            wasAutoCollapsed: false,
            userOverride: false
        )
        #expect(result == .noChange)
    }
}

struct WorkspaceSidebarWidthPolicyTests {
    @Test("dragged width clamps to sidebar bounds")
    func draggedWidthClampsToBounds() {
        #expect(
            WorkspaceSidebarWidthPolicy.draggedWidth(
                startWidth: WorkspaceSidebarWidthPolicy.defaultWidth,
                startX: 100,
                currentX: 20
            ) == WorkspaceSidebarWidthPolicy.minimumWidth
        )
        #expect(
            WorkspaceSidebarWidthPolicy.draggedWidth(
                startWidth: WorkspaceSidebarWidthPolicy.defaultWidth,
                startX: 100,
                currentX: 260
            ) == WorkspaceSidebarWidthPolicy.maximumWidth
        )
    }

    @Test("dragged width preserves in-range deltas")
    func draggedWidthPreservesInRangeDeltas() {
        #expect(
            WorkspaceSidebarWidthPolicy.draggedWidth(
                startWidth: 320,
                startX: 100,
                currentX: 125
            ) == 345
        )
    }
}
