import AppKit
import Foundation
import GhosthubWorkspace
import SwiftUI
import Synchronization
import Testing
@testable import GhosthubUI

@MainActor
@Suite("Native tmux presentation lifecycle")
struct TmuxSessionPresentationLifecycleTests {
    enum CrossHostHerdrIntent: Sendable {
        case open
        case restart
    }

    enum HerdrTransitionEvent: Equatable {
        case deactivate
        case start
    }

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

    @Test("validated Herdr activation closes the tmux presentation it replaced")
    func herdrActivationClosesReplacedTmuxAfterValidation() async throws {
        let hostID = UUID()
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: hostID,
            name: "agents"
        )
        let tmux = WorkspaceTmuxSessionSelection(
            hostID: hostID,
            name: "editor"
        )
        var closedTmuxSessions: [WorkspaceTmuxSessionSelection] = []

        let didActivate = try await RootView.openHerdrSession(
            herdr,
            replacing: tmux,
            open: { _ in },
            closeTmux: { closedTmuxSessions.append($0) }
        )
        #expect(didActivate)
        #expect(closedTmuxSessions == [tmux])

        let staleActivation = try await RootView.openHerdrSession(
            herdr,
            replacing: tmux,
            open: { _ in },
            isCurrent: { false },
            closeTmux: { closedTmuxSessions.append($0) }
        )
        #expect(!staleActivation)
        #expect(closedTmuxSessions == [tmux])

        await #expect(throws: CancellationError.self) {
            try await RootView.openHerdrSession(
                herdr,
                replacing: tmux,
                open: { _ in throw CancellationError() },
                closeTmux: { closedTmuxSessions.append($0) }
            )
        }
        #expect(closedTmuxSessions == [tmux])
    }

    @Test(
        "cross-host Herdr intents deactivate before starting",
        arguments: [CrossHostHerdrIntent.open, .restart]
    )
    func crossHostHerdrIntentOrdering(intent: CrossHostHerdrIntent) {
        let active = WorkspaceHerdrSessionSelection(
            hostID: UUID(),
            name: "current"
        )
        let target = WorkspaceHerdrSessionSelection(
            hostID: UUID(),
            name: intent == .open ? "running" : "stopped"
        )
        var events: [HerdrTransitionEvent] = []

        RootView.transitionHerdrSession(
            to: target,
            from: active,
            deactivate: { session in
                #expect(session == active)
                events.append(.deactivate)
            },
            start: {
                events.append(.start)
            }
        )

        #expect(events == [.deactivate, .start])
    }

    @Test("Herdr restart supersedes a delayed activation")
    func herdrRestartSupersedesDelayedActivation() async {
        let activationContinuation =
            Mutex<CheckedContinuation<Void, Never>?>(nil)
        let controller = HerdrPresentationIntentController()
        var completions: [String] = []
        var failures: [String] = []
        var activationReturned = false

        controller.start(
            operation: { isCurrent in
                await withCheckedContinuation { continuation in
                    activationContinuation.withLock { $0 = continuation }
                }
                defer { activationReturned = true }
                guard isCurrent() else { return }
                completions.append("activation")
            },
            onFailure: { failures.append($0.localizedDescription) }
        )
        for _ in 0 ..< 1_000 {
            if activationContinuation.withLock({ $0 != nil }) {
                break
            }
            await Task.yield()
        }

        controller.start(
            operation: { isCurrent in
                guard isCurrent() else { return }
                completions.append("restart")
            },
            onFailure: { failures.append($0.localizedDescription) }
        )
        for _ in 0 ..< 1_000 {
            if completions == ["restart"] {
                break
            }
            await Task.yield()
        }

        let continuation = activationContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        continuation?.resume()
        for _ in 0 ..< 1_000 {
            if activationReturned {
                break
            }
            await Task.yield()
        }

        #expect(activationReturned)
        #expect(completions == ["restart"])
        #expect(failures.isEmpty)
    }

    @Test("newer Herdr lifecycle preparation supersedes and releases older authority")
    func herdrLifecyclePreparationSupersedesOlderRequest() async {
        let host = HostSummary.fixture()
        let first = HerdrSessionLifecycleRequest(
            authorityID: UUID(),
            session: .init(hostID: host.id, name: "first"),
            confirmedHost: host,
            isDefault: false,
            confirmedSessionDirectory: "/tmp/first",
            confirmedSocketPath: "/tmp/first.sock",
            action: .stop
        )
        let second = HerdrSessionLifecycleRequest(
            authorityID: UUID(),
            session: .init(hostID: host.id, name: "second"),
            confirmedHost: host,
            isDefault: false,
            confirmedSessionDirectory: "/tmp/second",
            confirmedSocketPath: "/tmp/second.sock",
            action: .delete
        )
        let firstContinuation = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let controller = HerdrLifecyclePreparationController()
        var prepared: [HerdrSessionLifecycleRequest] = []
        var cancelled: [HerdrSessionLifecycleRequest] = []
        var failures: [String] = []

        controller.start(
            prepare: {
                await withCheckedContinuation { continuation in
                    firstContinuation.withLock { $0 = continuation }
                }
                return first
            },
            cancelPrepared: { cancelled.append($0) },
            onPrepared: { prepared.append($0) },
            onFailure: { failures.append($0.localizedDescription) }
        )
        for _ in 0 ..< 1_000 {
            if firstContinuation.withLock({ $0 != nil }) {
                break
            }
            await Task.yield()
        }

        controller.start(
            prepare: { second },
            cancelPrepared: { cancelled.append($0) },
            onPrepared: { prepared.append($0) },
            onFailure: { failures.append($0.localizedDescription) }
        )
        for _ in 0 ..< 1_000 {
            if prepared == [second] {
                break
            }
            await Task.yield()
        }

        let continuation = firstContinuation.withLock {
            let continuation = $0
            $0 = nil
            return continuation
        }
        continuation?.resume()
        for _ in 0 ..< 1_000 {
            if cancelled == [first] {
                break
            }
            await Task.yield()
        }

        #expect(prepared == [second])
        #expect(cancelled == [first])
        #expect(failures.isEmpty)
    }

    @Test("Root presents only the active Herdr backend")
    func rootPresentsHerdrOnly() {
        let host = HostSummary.fixture()
        let herdr = WorkspaceHerdrSessionSelection(
            hostID: host.id,
            name: "api"
        )
        var selection = WorkspaceSelection(selectedHostID: host.id)
        let hostingView = hostView(
            RootView(
                display: WorkspaceDisplayState(
                    snapshot: .fixture(hosts: [host]),
                    activeHerdrSession: herdr
                ),
                content: ContentBuilders(
                    tmuxSessionContentBuilder: { _, _, _, _ in
                        AnyView(ActiveTmuxPresentationMarker())
                    },
                    herdrSessionContentBuilder: { _, _, _, _ in
                        AnyView(ActiveHerdrPresentationMarker())
                    }
                ),
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                )
            ),
            size: CGSize(width: 960, height: 640)
        )

        #expect(viewByAccessibilityID(
            "active-herdr-presentation",
            in: hostingView
        ) != nil)
        #expect(viewByAccessibilityID(
            "active-tmux-presentation",
            in: hostingView
        ) == nil)
    }

    @Test("Herdr survives selection collapse to its host route")
    func herdrSurvivesHostRouteSelectionCollapse() {
        let model = HerdrRoutePresentationModel()
        let hostingView = hostView(
            HerdrRoutePresentationHarness(model: model),
            size: CGSize(width: 100, height: 100)
        )

        model.selectHostRoute()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(model.closedSessions.isEmpty)
        withExtendedLifetime(hostingView) {}
    }

    @Test(
        "navigation away from a Herdr host route closes its presentation",
        arguments: [
            HerdrRouteNavigation.project,
            .worktree,
            .directoryWorkspace,
            .anotherHost,
        ]
    )
    func navigationAwayClosesHerdr(
        navigation: HerdrRouteNavigation
    ) {
        let model = HerdrRoutePresentationModel()
        let hostingView = hostView(
            HerdrRoutePresentationHarness(model: model),
            size: CGSize(width: 100, height: 100)
        )

        model.selectHostRoute()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        model.navigate(navigation)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(model.closedSessions == [model.activeSession])
        withExtendedLifetime(hostingView) {}
    }

    @Test("Root refuses contradictory native presentations")
    func rootRefusesContradictoryPresentations() {
        let host = HostSummary.fixture()
        var selection = WorkspaceSelection(selectedHostID: host.id)
        let hostingView = hostView(
            RootView(
                display: WorkspaceDisplayState(
                    snapshot: .fixture(hosts: [host]),
                    activeTmuxSession: WorkspaceTmuxSessionSelection(
                        hostID: host.id,
                        name: "tmux"
                    ),
                    activeHerdrSession: WorkspaceHerdrSessionSelection(
                        hostID: host.id,
                        name: "herdr"
                    )
                ),
                content: ContentBuilders(
                    tmuxSessionContentBuilder: { _, _, _, _ in
                        AnyView(ActiveTmuxPresentationMarker())
                    },
                    herdrSessionContentBuilder: { _, _, _, _ in
                        AnyView(ActiveHerdrPresentationMarker())
                    }
                ),
                selection: Binding(
                    get: { selection },
                    set: { selection = $0 }
                )
            ),
            size: CGSize(width: 960, height: 640)
        )

        #expect(viewByAccessibilityID(
            "active-herdr-presentation",
            in: hostingView
        ) == nil)
        #expect(viewByAccessibilityID(
            "active-tmux-presentation",
            in: hostingView
        ) == nil)
    }

    @Test("a stable tmux recovery request auto-opens only once")
    func stableTmuxRecoveryRequestOpensOnce() {
        let request = SessionConnectionRecoveryRequest(
            hostID: UUID(),
            message: "SSH authentication is required."
        )
        var router = SessionConnectionRecoveryRequestRouter()

        #expect(
            router.take(request, whileReviewIsPresented: false) == request
        )
        #expect(router.take(request, whileReviewIsPresented: false) == nil)
    }

    @Test("alternating dismissed tmux recovery requests stay dismissed")
    func alternatingDismissedTmuxRecoveryRequestsStayDismissed() {
        let firstHostID = UUID()
        let secondHostID = UUID()
        let first = SessionConnectionRecoveryRequest(
            hostID: firstHostID,
            message: "SSH authentication is required."
        )
        let second = SessionConnectionRecoveryRequest(
            hostID: secondHostID,
            message: "The SSH host key needs review."
        )
        var router = SessionConnectionRecoveryRequestRouter()

        #expect(router.take(first, whileReviewIsPresented: false) == first)
        router.reviewDidDismiss()
        #expect(router.take(second, whileReviewIsPresented: false) == second)
        router.reviewDidDismiss()
        #expect(router.take(first, whileReviewIsPresented: false) == nil)
        #expect(router.take(second, whileReviewIsPresented: false) == nil)

        let manualReviewRequestID = router.recoveryRequestID(
            for: firstHostID,
            activeRequest: first
        )
        #expect(
            router.recoveryRequestToResume(
                reviewedHostID: firstHostID,
                reviewRequestID: manualReviewRequestID
            ) == first
        )
    }

    @Test("tmux recovery waits for an existing SSH review to dismiss")
    func tmuxRecoveryWaitsForExistingReview() {
        let request = SessionConnectionRecoveryRequest(
            hostID: UUID(),
            message: "SSH authentication is required."
        )
        var router = SessionConnectionRecoveryRequestRouter()

        #expect(
            router.take(request, whileReviewIsPresented: true) == nil
        )
        #expect(
            router.take(request, whileReviewIsPresented: false) == request
        )
    }

    @Test("retrying resolved tmux recovery resumes the paused host")
    func resolvedTmuxRecoveryRetryResumesPausedHost() {
        let hostID = UUID()
        let request = SessionConnectionRecoveryRequest(
            hostID: hostID,
            message: "SSH authentication is required."
        )
        var router = SessionConnectionRecoveryRequestRouter()
        _ = router.take(request, whileReviewIsPresented: false)

        #expect(
            router.recoveryRequestToResume(
                reviewedHostID: hostID,
                reviewRequestID: request.id
            ) == request
        )
    }

    @Test("unrelated SSH authentication cannot resume tmux recovery")
    func unrelatedSSHAuthenticationCannotResumeTmuxRecovery() {
        let hostID = UUID()
        let request = SessionConnectionRecoveryRequest(
            hostID: hostID,
            message: "SSH authentication is required."
        )
        var router = SessionConnectionRecoveryRequestRouter()
        _ = router.take(request, whileReviewIsPresented: false)

        #expect(
            router.recoveryRequestToResume(
                reviewedHostID: hostID,
                reviewRequestID: nil
            ) == nil
        )
    }

    @Test("successful manual review resumes the active tmux recovery")
    func successfulManualReviewResumesActiveTmuxRecovery() {
        let hostID = UUID()
        let request = SessionConnectionRecoveryRequest(
            hostID: hostID,
            message: "SSH authentication is required."
        )
        var router = SessionConnectionRecoveryRequestRouter()
        _ = router.take(request, whileReviewIsPresented: false)
        let manualReviewRequestID = router.recoveryRequestID(
            for: hostID,
            activeRequest: request
        )

        #expect(
            router.recoveryRequestToResume(
                reviewedHostID: hostID,
                reviewRequestID: manualReviewRequestID
            ) == request
        )
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

    @Test("navigation hides an initially restored unbound session")
    func navigationHidesInitiallyRestoredUnboundSession() {
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

        #expect(model.hiddenSessions.count == 1)
        #expect(model.hiddenSessions.first?.name == "docbank")
        #expect(model.closedSessions.isEmpty)
        withExtendedLifetime(hostingView) {}
    }

    @Test("navigation hides an initially restored directory workspace")
    func navigationHidesInitiallyRestoredDirectoryWorkspace() {
        let hostID = UUID()
        let directoryID = UUID()
        let model = EndpointChangePresentationModel(
            hostID: hostID,
            activeSession: WorkspaceTmuxSessionSelection(
                hostID: hostID,
                name: "kwt-workspace-dir-hub",
                directoryWorkspaceID: directoryID,
                workspacePath: "/srv/hub"
            )
        )
        let hostingView = hostView(
            EndpointChangePresentationHarness(model: model),
            size: CGSize(width: 960, height: 640)
        )

        model.navigateToAnotherHost()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        #expect(model.hiddenSessions.count == 1)
        #expect(model.hiddenSessions.first?.directoryWorkspaceID == directoryID)
        #expect(model.closedSessions.isEmpty)
        withExtendedLifetime(hostingView) {}
    }
}

@MainActor
private final class EndpointChangePresentationModel: ObservableObject {
    @Published var display: WorkspaceDisplayState
    @Published var selection: WorkspaceSelection
    private(set) var hiddenSessions: [WorkspaceTmuxSessionSelection] = []
    private(set) var closedSessions: [WorkspaceTmuxSessionSelection] = []
    private let alternateHostID = UUID()
    private let directoryWorkspace: DirectoryWorkspaceSummary?
    let hostID: UUID

    init(
        hostID: UUID,
        activeSession: WorkspaceTmuxSessionSelection
    ) {
        self.hostID = hostID
        directoryWorkspace = if let directoryID =
            activeSession.directoryWorkspaceID,
            let workspacePath = activeSession.workspacePath {
            DirectoryWorkspaceSummary(
                id: directoryID,
                hostID: hostID,
                name: "hub",
                path: workspacePath,
                tmuxSessionName: activeSession.name,
                sessionLive: true
            )
        } else {
            nil
        }
        selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedDirectoryWorkspaceID: activeSession.directoryWorkspaceID
        )
        display = Self.display(
            hostID: hostID,
            alternateHostID: alternateHostID,
            destination: "old-builder",
            activeSession: activeSession,
            directoryWorkspace: directoryWorkspace
        )
    }

    func replaceEndpointAndInvalidatePresentation() {
        display = Self.display(
            hostID: hostID,
            alternateHostID: alternateHostID,
            destination: "new-builder",
            activeSession: nil,
            directoryWorkspace: directoryWorkspace
        )
    }

    func navigateToAnotherHost() {
        selection = WorkspaceSelection(selectedHostID: alternateHostID)
    }

    func recordClosedSession(_ session: WorkspaceTmuxSessionSelection) {
        closedSessions.append(session)
    }

    func recordHiddenSession(_ session: WorkspaceTmuxSessionSelection) {
        hiddenSessions.append(session)
        display = Self.display(
            hostID: hostID,
            alternateHostID: alternateHostID,
            destination: "old-builder",
            activeSession: nil,
            directoryWorkspace: directoryWorkspace
        )
    }

    private static func display(
        hostID: UUID,
        alternateHostID: UUID,
        destination: String,
        activeSession: WorkspaceTmuxSessionSelection?,
        directoryWorkspace: DirectoryWorkspaceSummary?
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
                worktrees: [],
                directoryWorkspaces: directoryWorkspace.map { [$0] } ?? []
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
                tmuxSessionContentBuilder: { _, _, _, _ in
                    AnyView(
                        ActiveTmuxPresentationMarker()
                    )
                }
            ),
            handlers: InteractionHandlers(
                hideTmuxSession: model.recordHiddenSession,
                closeTmuxSession: model.recordClosedSession
            ),
            selection: $model.selection
        )
    }
}

enum HerdrRouteNavigation: Sendable {
    case project
    case worktree
    case directoryWorkspace
    case anotherHost
}

@MainActor
private final class HerdrRoutePresentationModel: ObservableObject {
    @Published var selection: WorkspaceSelection
    let activeSession: WorkspaceHerdrSessionSelection
    private(set) var closedSessions: [WorkspaceHerdrSessionSelection] = []

    private let hostID: UUID
    private let alternateHostID: UUID
    private let projectID: UUID
    private let worktreeID: UUID
    private let directoryWorkspaceID: UUID

    init() {
        hostID = UUID()
        alternateHostID = UUID()
        projectID = UUID()
        worktreeID = UUID()
        directoryWorkspaceID = UUID()
        activeSession = WorkspaceHerdrSessionSelection(
            hostID: hostID,
            name: "agent"
        )
        selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: projectID,
            selectedWorktreeID: worktreeID
        )
    }

    func selectHostRoute() {
        selection = WorkspaceSelection(selectedHostID: hostID)
    }

    func navigate(_ navigation: HerdrRouteNavigation) {
        switch navigation {
        case .project:
            selection = WorkspaceSelection(
                selectedHostID: hostID,
                selectedProjectID: projectID
            )
        case .worktree:
            selection = WorkspaceSelection(
                selectedHostID: hostID,
                selectedProjectID: projectID,
                selectedWorktreeID: worktreeID
            )
        case .directoryWorkspace:
            selection = WorkspaceSelection(
                selectedHostID: hostID,
                selectedDirectoryWorkspaceID: directoryWorkspaceID
            )
        case .anotherHost:
            selection = WorkspaceSelection(selectedHostID: alternateHostID)
        }
    }

    func recordClosedSession(_ session: WorkspaceHerdrSessionSelection) {
        closedSessions.append(session)
    }
}

private struct HerdrRoutePresentationHarness: View {
    @ObservedObject var model: HerdrRoutePresentationModel

    var body: some View {
        Color.clear.modifier(
            HerdrSessionPresentationLifecycleModifier(
                selection: model.selection,
                activeSession: model.activeSession,
                deactivate: { session in
                    model.recordClosedSession(session)
                }
            )
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

private struct ActiveHerdrPresentationMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityIdentifier("active-herdr-presentation")
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
