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

    @Test("an explicit tab request adopts the next workspace")
    func explicitTabRequestAdoptsNextWorkspace() {
        let parent = Window(isWorkspace: true)
        let newWindow = Window(isWorkspace: true)
        let request = PendingWorkspaceTab<Window>()

        request.request(from: parent)

        #expect(request.consumeParent(for: newWindow) === parent)
        #expect(request.consumeParent(for: newWindow) == nil)
    }

    @Test("an independent window request cannot adopt")
    func independentWindowDoesNotAdopt() {
        let parent = Window(isWorkspace: true)
        let newWindow = Window(isWorkspace: true)
        let request = PendingWorkspaceTab<Window>()

        request.request(from: parent)
        request.requestIndependentWindow()

        #expect(request.consumeParent(for: newWindow) == nil)
    }

    @Test("the requesting window appearing again does not consume the request")
    func requestingWindowDoesNotConsumeRequest() {
        let parent = Window(isWorkspace: true)
        let newWindow = Window(isWorkspace: true)
        let request = PendingWorkspaceTab<Window>()

        request.request(from: parent)

        #expect(request.consumeParent(for: parent) == nil)
        #expect(request.consumeParent(for: newWindow) === parent)
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
