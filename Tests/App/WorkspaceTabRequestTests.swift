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
        let firstState = WorkspaceWindowState.fresh()
        let secondState = WorkspaceWindowState.fresh()
        let firstParent = Window(isWorkspace: true)
        let secondParent = Window(isWorkspace: true)
        let firstWindow = Window(isWorkspace: true)
        let secondWindow = Window(isWorkspace: true)
        let requests = WorkspaceWindowRequests<Window>()

        requests.add(firstState.windowID, parent: firstParent)
        requests.add(secondState.windowID, parent: secondParent)

        #expect(
            requests.consume(
                for: secondState.windowID,
                window: secondWindow
            )?.parent === secondParent
        )
        #expect(
            requests.consume(
                for: firstState.windowID,
                window: firstWindow
            )?.parent === firstParent
        )
    }

    @Test("an independent request does not overwrite tab intent")
    func independentRequestDoesNotOverwriteTab() {
        let tabState = WorkspaceWindowState.fresh()
        let independentState = WorkspaceWindowState.fresh()
        let restoredState = WorkspaceWindowState.fresh()
        let parent = Window(isWorkspace: true)
        let tabWindow = Window(isWorkspace: true)
        let independentWindow = Window(isWorkspace: true)
        let requests = WorkspaceWindowRequests<Window>()

        requests.add(tabState.windowID, parent: parent)
        requests.add(independentState.windowID, parent: nil)

        let independent = requests.consume(
            for: independentState.windowID,
            window: independentWindow
        )
        #expect(independent != nil)
        #expect(independent?.parent == nil)
        #expect(
            requests.consume(
                for: restoredState.windowID,
                window: independentWindow
            ) == nil
        )
        #expect(
            requests.consume(
                for: tabState.windowID,
                window: tabWindow
            )?.parent === parent
        )
        #expect(
            requests.consume(
                for: tabState.windowID,
                window: tabWindow
            ) == nil
        )
    }

    @Test("a group request preserves the remaining tab order")
    func groupRequestPreservesRemainingOrder() {
        let first = WorkspaceWindowState.fresh()
        let second = WorkspaceWindowState.fresh()
        let third = WorkspaceWindowState.fresh()
        let window = Window(isWorkspace: true)
        let requests = WorkspaceWindowRequests<Window>()

        requests.add(
            first.windowID,
            parent: nil,
            remainingStates: [second, third]
        )

        let request = requests.consume(
            for: first.windowID,
            window: window
        )

        #expect(request?.parent == nil)
        #expect(request?.remainingStates.map(\.windowID) == [
            second.windowID,
            third.windowID,
        ])
        #expect(request?.requiredParentMissing == false)
    }

    @Test("a request stops when its required tab parent disappears")
    func requiredParentLossStopsRequest() throws {
        let state = WorkspaceWindowState.fresh()
        let remaining = WorkspaceWindowState.fresh()
        var parent: Window? = Window(isWorkspace: true)
        let child = Window(isWorkspace: true)
        let requests = WorkspaceWindowRequests<Window>()

        requests.add(
            state.windowID,
            parent: parent,
            remainingStates: [remaining]
        )
        parent = nil

        let request = try #require(requests.consume(
            for: state.windowID,
            window: child
        ))
        #expect(request.requiredParentMissing)
        #expect(request.parent == nil)
        #expect(request.remainingStates.map(\.windowID) == [
            remaining.windowID,
        ])
    }

    @Test("window launch intents are ephemeral and one shot")
    func windowLaunchIntentsAreEphemeral() {
        let firstID = UUID()
        let secondID = UUID()
        let intents = WorkspaceWindowLaunchIntents()

        intents.add(.openWorktree, for: [firstID, secondID])

        #expect(intents.consume(for: firstID) == .openWorktree)
        #expect(intents.consume(for: firstID) == nil)
        #expect(intents.consume(for: secondID) == .openWorktree)
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
