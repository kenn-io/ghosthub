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

    @Test("restoration suppression stays idle until explicit selection")
    func restorationSuppressionStaysIdle() {
        let hostID = UUID()
        let project = ProjectSummary.fixture(hostID: hostID)
        var worktree = WorktreeSummary.fixture(
            hostID: hostID,
            projectID: project.id
        )
        worktree.tmuxSessionName = "editor"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [.fixture(id: hostID)],
            projects: [project],
            worktrees: [worktree]
        )
        var selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: project.id,
            selectedWorktreeID: worktree.id
        )
        var requestedSessions: [WorkspaceTmuxSessionSelection] = []

        let hostingView = hostView(
            RootView(
                display: WorkspaceDisplayState(
                    snapshot: snapshot,
                    suppressesAutomaticWorktreeSessionOpen: true
                ),
                handlers: InteractionHandlers(
                    openTmuxSession: { requestedSessions.append($0) }
                ),
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                )
            ),
            size: CGSize(width: 960, height: 640)
        )

        #expect(requestedSessions.isEmpty)
        #expect(
            !viewDescendants(of: hostingView).contains {
                $0 is NSProgressIndicator
            }
        )
        withExtendedLifetime(hostingView) {}
    }

    @Test("automatic selection normalization is not explicit navigation")
    func automaticNormalizationDoesNotNavigate() {
        let environment = makeWorkspaceEnvironment()
        var selection = WorkspaceSelection(
            selectedHostID: environment.host.id,
            selectedProjectID: environment.project.id,
            selectedWorktreeID: UUID()
        )
        var explicitSelections: [WorkspaceSelection] = []

        let hostingView = hostView(
            RootView(
                display: WorkspaceDisplayState(
                    snapshot: environment.snapshot
                ),
                handlers: InteractionHandlers(
                    selectWorkspace: { explicitSelections.append($0) }
                ),
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                )
            ),
            size: CGSize(width: 960, height: 640)
        )

        #expect(explicitSelections.isEmpty)
        #expect(selection.selectedWorktreeID == environment.worktrees[0].id)
        withExtendedLifetime(hostingView) {}
    }

    @Test(
        "non-authoritative generation does not replace active presentation",
        arguments: ["generation-b", nil] as [String?]
    )
    func nonAuthoritativeGenerationDoesNotReplaceActivePresentation(
        _ generation: String?
    ) {
        let model = WorktreeReplacementPresentationModel()
        var requestedSessions: [WorkspaceTmuxSessionSelection] = []
        let hostingView = hostView(
            WorktreeReplacementPresentationHarness(
                model: model,
                onOpen: { requestedSessions.append($0) }
            ),
            size: CGSize(width: 960, height: 640)
        )

        #expect(requestedSessions.isEmpty)

        model.refreshWorktreeGeneration(generation)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(requestedSessions.isEmpty)
        withExtendedLifetime(hostingView) {}
    }

    @Test("generation enrichment does not reopen the active presentation")
    func generationEnrichmentKeepsActivePresentation() {
        let model = WorktreeReplacementPresentationModel(generation: nil)
        var requestedSessions: [WorkspaceTmuxSessionSelection] = []
        let hostingView = hostView(
            WorktreeReplacementPresentationHarness(
                model: model,
                onOpen: { requestedSessions.append($0) }
            ),
            size: CGSize(width: 960, height: 640)
        )

        #expect(requestedSessions.isEmpty)

        model.refreshWorktreeGeneration(
            "0123456789abcdef0123456789abcdef"
        )
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(requestedSessions.isEmpty)
        withExtendedLifetime(hostingView) {}
    }

    @Test("releasing restoration suppression opens an unchanged selection")
    func releasedSuppressionSynchronizesUnchangedSelection() {
        let model = WorktreeReplacementPresentationModel()
        var requestedSessions: [WorkspaceTmuxSessionSelection] = []
        let hostingView = hostView(
            WorktreeReplacementPresentationHarness(
                model: model,
                onOpen: { requestedSessions.append($0) }
            ),
            size: CGSize(width: 960, height: 640)
        )

        model.setRestorationSuppression(true)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(requestedSessions.isEmpty)

        model.setRestorationSuppression(false)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(requestedSessions.count == 1)
        #expect(requestedSessions.first?.name == "editor")
        withExtendedLifetime(hostingView) {}
    }

    @Test("navigation detaches an initially restored unbound session")
    func navigationDetachesInitiallyRestoredUnboundSession() {
        let hostID = UUID()
        let model = EndpointChangePresentationModel(
            hostID: hostID,
            activeSession: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "docbank"
            )
        )
        let hostingView = hostView(
            EndpointChangePresentationHarness(model: model),
            size: CGSize(width: 960, height: 640)
        )

        model.navigateToAnotherHost()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(model.closedSessions.count == 1)
        #expect(model.closedSessions.first?.name == "docbank")
        withExtendedLifetime(hostingView) {}
    }
}

@MainActor
private final class EndpointChangePresentationModel: ObservableObject {
    @Published var display: WorkspaceDisplayState
    @Published var selection: WorkspaceSelection
    private(set) var closedSessions: [WorkspaceTmuxSessionSelection] = []
    private let alternateHostID = UUID()
    let hostID: UUID

    init(
        hostID: UUID,
        activeSession: WorkspaceTmuxSessionSelection
    ) {
        self.hostID = hostID
        selection = WorkspaceSelection(selectedHostID: hostID)
        display = Self.display(
            hostID: hostID,
            alternateHostID: alternateHostID,
            destination: "old-builder",
            activeSession: activeSession
        )
    }

    func replaceEndpointAndInvalidatePresentation() {
        display = Self.display(
            hostID: hostID,
            alternateHostID: alternateHostID,
            destination: "new-builder",
            activeSession: nil
        )
    }

    func navigateToAnotherHost() {
        selection = WorkspaceSelection(selectedHostID: alternateHostID)
    }

    func recordClosedSession(_ session: WorkspaceTmuxSessionSelection) {
        closedSessions.append(session)
    }

    private static func display(
        hostID: UUID,
        alternateHostID: UUID,
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
                hosts: [host, .fixture(id: alternateHostID)],
                projects: [],
                worktrees: []
            ),
            activeTmuxSession: activeSession
        )
    }
}

private struct EndpointChangePresentationHarness: View {
    @ObservedObject var model: EndpointChangePresentationModel

    var body: some View {
        RootView(
            display: model.display,
            content: ContentBuilders(
                tmuxSessionContentBuilder: { _, _, _ in
                    AnyView(
                        ActiveTmuxPresentationMarker()
                    )
                }
            ),
            handlers: InteractionHandlers(
                closeTmuxSession: model.recordClosedSession
            ),
            selection: $model.selection
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

@MainActor
private final class WorktreeReplacementPresentationModel: ObservableObject {
    @Published var display: WorkspaceDisplayState
    let selection: WorkspaceSelection

    init(generation: String? = "generation-a") {
        let host = HostSummary.fixture()
        let project = ProjectSummary.fixture(hostID: host.id)
        var worktree = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id
        )
        worktree.generation = generation
        worktree.tmuxSessionName = "editor"
        let snapshot = WorkspaceSnapshot.fixture(
            hosts: [host],
            projects: [project],
            worktrees: [worktree]
        )
        selection = WorkspaceSelection(
            selectedHostID: host.id,
            selectedProjectID: project.id,
            selectedWorktreeID: worktree.id
        )
        display = WorkspaceDisplayState(
            snapshot: snapshot,
            activeTmuxSession: WorkspaceTmuxSessionSelection(
                hostID: host.id,
                name: "editor",
                worktreeID: worktree.id,
                worktreePath: worktree.path,
                worktreeGeneration: generation
            )
        )
    }

    func refreshWorktreeGeneration(_ generation: String?) {
        var worktree = display.snapshot.worktrees[0]
        worktree.generation = generation
        display = WorkspaceDisplayState(
            snapshot: WorkspaceSnapshot.fixture(
                hosts: display.snapshot.hosts,
                projects: display.snapshot.projects,
                worktrees: [worktree]
            ),
            activeTmuxSession: display.activeTmuxSession
        )
    }

    func setRestorationSuppression(_ isSuppressed: Bool) {
        display = WorkspaceDisplayState(
            snapshot: display.snapshot,
            suppressesAutomaticWorktreeSessionOpen: isSuppressed
        )
    }
}

private struct WorktreeReplacementPresentationHarness: View {
    @ObservedObject var model: WorktreeReplacementPresentationModel
    let onOpen: (WorkspaceTmuxSessionSelection) -> Void
    @State private var selection: WorkspaceSelection

    init(
        model: WorktreeReplacementPresentationModel,
        onOpen: @escaping (WorkspaceTmuxSessionSelection) -> Void
    ) {
        self.model = model
        self.onOpen = onOpen
        _selection = State(initialValue: model.selection)
    }

    var body: some View {
        RootView(
            display: model.display,
            handlers: InteractionHandlers(openTmuxSession: onOpen),
            selection: $selection
        )
    }
}
