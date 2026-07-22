import AppKit
import Foundation
import GhosthubWorkspace
import SwiftUI
import Testing
@testable import GhosthubUI

@MainActor
@Suite("Native tmux presentation lifecycle")
struct TmuxSessionPresentationLifecycleTests {
    @Test("creating a host session clears a selected worktree")
    func creationSelectsHostSession() {
        let hostID = UUID()
        let project = ProjectSummary.fixture(hostID: hostID)
        let worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id
        )
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [project],
            worktrees: [worktree]
        )
        let current = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: project.id,
            selectedWorktreeID: worktree.id
        )

        let updated = RootView.selectionForHostTmuxSession(
            WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "release-work"
            ),
            from: current,
            in: snapshot,
            visibility: .default
        )

        #expect(updated.selectedHostID == hostID)
        #expect(updated.selectedProjectID == nil)
        #expect(updated.selectedWorktreeID == nil)
    }

    @Test("Cmd-W detaches an active tmux presentation")
    func closeDetachesActivePresentation() {
        var didDetach = false
        let handled = RootView.closeBorrowedSessionIfActive(
            WorkspaceTmuxSessionSelection(hostID: UUID(), name: "docbank")
        ) {
            didDetach = true
        }

        #expect(handled)
        #expect(didDetach)
    }

    @Test("Cmd-W falls through when no tmux presentation is active")
    func closeFallsThroughWithoutPresentation() {
        var didDetach = false
        let handled = RootView.closeBorrowedSessionIfActive(nil) {
            didDetach = true
        }

        #expect(!handled)
        #expect(!didDetach)
    }

    @Test("endpoint invalidation removes the active tmux presentation")
    func endpointInvalidationRemovesActivePresentation() {
        let hostID = UUID()
        let session = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "docbank"
        )
        let model = EndpointChangePresentationModel(
            hostID: hostID,
            activeSession: session
        )
        let hostingView = hostView(
            EndpointChangePresentationHarness(model: model),
            size: CGSize(width: 960, height: 640)
        )

        #expect(
            viewByAccessibilityID(
                "active-tmux-presentation",
                in: hostingView
            ) != nil
        )

        model.replaceEndpointAndInvalidatePresentation()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(
            viewByAccessibilityID(
                "active-tmux-presentation",
                in: hostingView
            ) == nil
        )
    }
}

@MainActor
private final class EndpointChangePresentationModel: ObservableObject {
    @Published var display: WorkspaceDisplayState
    let hostID: UUID

    init(
        hostID: UUID,
        activeSession: WorkspaceTmuxSessionSelection
    ) {
        self.hostID = hostID
        display = Self.display(
            hostID: hostID,
            destination: "old-builder",
            activeSession: activeSession
        )
    }

    func replaceEndpointAndInvalidatePresentation() {
        display = Self.display(
            hostID: hostID,
            destination: "new-builder",
            activeSession: nil
        )
    }

    private static func display(
        hostID: UUID,
        destination: String,
        activeSession: WorkspaceTmuxSessionSelection?
    ) -> WorkspaceDisplayState {
        let host = HostSummary(
            id: hostID,
            configKey: "builder",
            name: "Builder",
            kind: .remote,
            platform: .linux,
            sshDestination: destination,
            preferredTransport: .ssh,
            lastKnownReachable: true,
            tmuxSessions: [
                TmuxSessionSummary(
                    name: "docbank",
                    managed: false,
                    windows: []
                ),
            ]
        )
        return WorkspaceDisplayState(
            snapshot: WorkspaceSnapshot(
                hosts: [host],
                projects: [],
                worktrees: []
            ),
            activeTmuxSession: activeSession
        )
    }
}

private struct EndpointChangePresentationHarness: View {
    @ObservedObject var model: EndpointChangePresentationModel
    @State private var selection: WorkspaceSelection

    init(model: EndpointChangePresentationModel) {
        self.model = model
        _selection = State(
            initialValue: WorkspaceSelection(
                selectedHostID: model.hostID
            )
        )
    }

    var body: some View {
        RootView(
            display: model.display,
            content: ContentBuilders(
                tmuxSessionContentBuilder: { _, _ in
                    AnyView(
                        ActiveTmuxPresentationMarker()
                    )
                }
            ),
            selection: $selection
        )
    }
}

private struct ActiveTmuxPresentationMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier("active-tmux-presentation")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
