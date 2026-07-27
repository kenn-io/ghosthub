import Foundation
import Testing
@testable import GhosthubApp

@Suite("Workspace tab requests")
struct WorkspaceTabRequestTests {
    private final class Window {
        let isWorkspace: Bool
        var sheetParent: Window?

        init(
            isWorkspace: Bool,
            sheetParent: Window? = nil
        ) {
            self.isWorkspace = isWorkspace
            self.sheetParent = sheetParent
        }
    }

    @Test("outstanding requests retain their own tab parents")
    func outstandingRequestsRetainParents() {
        let firstID = UUID()
        let secondID = UUID()
        let firstParent = Window(isWorkspace: true)
        let secondParent = Window(isWorkspace: true)
        let firstWindow = Window(isWorkspace: true)
        let secondWindow = Window(isWorkspace: true)
        let requests = WorkspaceWindowRequests<Window>()

        requests.add(firstID, parent: firstParent)
        requests.add(secondID, parent: secondParent)

        #expect(
            requests.consumeParent(
                for: secondID,
                window: secondWindow
            ) === secondParent
        )
        #expect(
            requests.consumeParent(
                for: firstID,
                window: firstWindow
            ) === firstParent
        )
    }

    @Test("an independent request does not overwrite tab intent")
    func independentRequestDoesNotOverwriteTab() {
        let tabID = UUID()
        let windowID = UUID()
        let parent = Window(isWorkspace: true)
        let tabWindow = Window(isWorkspace: true)
        let independentWindow = Window(isWorkspace: true)
        let requests = WorkspaceWindowRequests<Window>()

        requests.add(tabID, parent: parent)
        requests.add(windowID, parent: nil)

        #expect(
            requests.consumeParent(
                for: windowID,
                window: independentWindow
            ) == nil
        )
        #expect(
            requests.consumeParent(
                for: tabID,
                window: tabWindow
            ) === parent
        )
        #expect(
            requests.consumeParent(
                for: tabID,
                window: tabWindow
            ) == nil
        )
    }

    @Test("a sheet resolves to its workspace parent")
    func sheetResolvesToWorkspace() {
        let workspace = Window(isWorkspace: true)
        let sheet = Window(
            isWorkspace: false,
            sheetParent: workspace
        )

        let resolved = WorkspaceWindowResolver.workspaceWindow(
            from: sheet,
            sheetParent: \.sheetParent,
            isWorkspace: \.isWorkspace
        )

        #expect(resolved === workspace)
    }

    @Test("a non-workspace window cannot become a tab parent")
    func rejectsNonWorkspaceWindow() {
        let unrelatedWindow = Window(isWorkspace: false)

        let resolved = WorkspaceWindowResolver.workspaceWindow(
            from: unrelatedWindow,
            sheetParent: \.sheetParent,
            isWorkspace: \.isWorkspace
        )

        #expect(resolved == nil)
    }
}
