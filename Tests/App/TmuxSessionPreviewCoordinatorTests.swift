import AppKit
import Combine
import Foundation
import GhosthubSettings
import GhosthubTerminal
import GhosthubTmux
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("Tmux session preview coordinator")
@MainActor
struct TmuxSessionPreviewCoordinatorTests {
    @Test("Efficient captures an expanded active session once")
    func efficientCapturesOnlyActivePresentation() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let active = harness.presentation(index: 0, isActive: true)
        let inactive = harness.presentation(index: 1, isActive: false)
        harness.coordinator.register(active)
        harness.coordinator.register(inactive)

        harness.coordinator.setExpanded(true, for: active.key)
        harness.coordinator.setExpanded(true, for: inactive.key)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [active.key])
        #expect(harness.parks.isEmpty)
    }

    @Test("Live captures the active surface and only granted parked surfaces")
    func liveRespectsInactiveBudget() async {
        let harness = PreviewCoordinatorHarness(mode: .live, budgetLimit: 1)
        let active = harness.presentation(index: 0, isActive: true)
        let granted = harness.presentation(index: 1, isActive: false)
        let waiting = harness.presentation(index: 2, isActive: false)
        for item in [active, granted, waiting] {
            harness.coordinator.register(item)
        }
        for item in [active, granted, waiting] {
            harness.coordinator.setExpanded(true, for: item.key)
        }

        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()

        #expect(!harness.parks.contains(active.key))
        #expect(harness.parks.contains(granted.key))
        #expect(!harness.parks.contains(waiting.key))
        #expect(Set(harness.captures) == [active.key, granted.key])
        #expect(
            harness.coordinator.viewState(for: waiting.key)?.placeholder
                == .liveLimitReached
        )
    }

    @Test("Always Live renders every expanded inactive presentation")
    func alwaysLiveBypassesInactiveBudget() async {
        let harness = PreviewCoordinatorHarness(
            mode: .alwaysLive,
            budgetLimit: 0
        )
        let first = harness.presentation(index: 0, isActive: false)
        let second = harness.presentation(index: 1, isActive: false)
        for item in [first, second] {
            harness.coordinator.register(item)
            harness.coordinator.setExpanded(true, for: item.key)
        }

        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()

        #expect(Set(harness.parks) == [first.key, second.key])
        #expect(Set(harness.captures) == [first.key, second.key])
        #expect(harness.budget.granted.isEmpty)
    }

    @Test("Always Live rejects a switched client's changed frame")
    func alwaysLiveRejectsChangedFrameAfterClientSwitch() async throws {
        let harness = PreviewCoordinatorHarness(mode: .alwaysLive)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)

        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()
        let authorizedFrame = try #require(
            harness.coordinator.viewState(for: presentation.key)?.frame
        )
        #expect(harness.identityRefreshes == 1)

        harness.setRefreshedIdentity(
            TmuxSessionIdentity(
                serverPID: "101",
                sessionID: "$replacement",
                createdAt: "1001"
            ),
            for: presentation.key
        )
        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()
        #expect(harness.identityRefreshes == 2)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame
                === authorizedFrame
        )

        harness.coordinator.remove(
            presentation.key,
            reason: .identityMismatch
        )
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame
                === authorizedFrame
        )

        harness.coordinator.setMode(.off)
        #expect(harness.coordinator.viewState(for: presentation.key) == nil)
    }

    @Test("a replacement registration clears a mismatched session's frame")
    func replacementRegistrationClearsMismatchedFrame() async throws {
        let harness = PreviewCoordinatorHarness(mode: .alwaysLive)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)

        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()
        let staleFrame = try #require(
            harness.coordinator.viewState(for: presentation.key)?.frame
        )

        harness.coordinator.remove(
            presentation.key,
            reason: .identityMismatch
        )
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame
                === staleFrame
        )

        let replacement = TmuxSessionPreviewCoordinator.Presentation(
            key: presentation.key,
            surface: { nil },
            handleID: {
                UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
            },
            generation: { "generation-replacement" },
            identity: { nil },
            connectionState: { .connecting },
            isActive: { false },
            activate: {}
        )
        harness.coordinator.register(replacement, identityIsResolved: false)

        let state = try #require(
            harness.coordinator.viewState(for: presentation.key)
        )
        #expect(state.frame == nil)
        #expect(state.placeholder == .awaitingFirstFrame)
    }

    @Test("a failed identity probe suppresses changed frames until recovery")
    func failedIdentityProbeSuppressesFramesUntilRecovery() async {
        let harness = PreviewCoordinatorHarness(mode: .alwaysLive)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.setRefreshedIdentity(nil, for: presentation.key)

        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()
        #expect(harness.identityRefreshes == 1)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame == nil
        )

        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()
        #expect(harness.identityRefreshes == 2)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame == nil
        )

        harness.setRefreshedIdentity(
            presentation.identity(),
            for: presentation.key
        )
        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()
        #expect(harness.identityRefreshes == 3)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test("Always Live waits for staged surface launch before parking")
    func alwaysLiveWaitsForSurfaceLaunchBeforeParking() {
        let harness = PreviewCoordinatorHarness(mode: .alwaysLive)
        var hasLaunched = false
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "session-0",
            socketName: nil
        )
        let presentation = TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { UUID() },
            generation: { "generation" },
            identity: { nil },
            connectionState: { .connecting },
            hasLaunched: { hasLaunched },
            isActive: { false },
            activate: {}
        )
        harness.coordinator.register(
            presentation,
            identityIsResolved: false
        )

        harness.coordinator.setExpanded(true, for: key)

        #expect(harness.parks.isEmpty)

        hasLaunched = true
        harness.coordinator.presentationDidChange(key)

        #expect(harness.parks == [key])
        #expect(harness.captures.isEmpty)
    }

    @Test("Always Live leaves unavailable identities unmounted")
    func alwaysLiveLeavesUnavailableIdentityUnmounted() {
        let harness = PreviewCoordinatorHarness(mode: .alwaysLive)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(
            presentation,
            identityIsUnavailable: true
        )

        harness.coordinator.setExpanded(true, for: presentation.key)

        #expect(harness.parks.isEmpty)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.placeholder
                == .unavailable
        )
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.isLive
                == false
        )
    }

    @Test("Live scheduling never exceeds two frames per second")
    func liveRateIsCapped() async {
        let recorder = PreviewIntervalRecorder()
        let coordinator = TmuxSessionPreviewCoordinator(
            mode: .live,
            budget: LivePreviewBudget(limit: 4),
            capture: { _, _ in nil },
            park: { _ in },
            unpark: { _ in },
            isKeyWindow: { true },
            sleep: { duration in
                await recorder.record(duration)
                throw CancellationError()
            },
            liveInterval: .milliseconds(1)
        )
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "active",
            socketName: nil
        )
        coordinator.register(.init(
            key: key,
            surface: { nil },
            handleID: { UUID() },
            generation: { "generation" },
            identity: {
                TmuxSessionIdentity(
                    serverPID: "101",
                    sessionID: "$1",
                    createdAt: "1000"
                )
            },
            connectionState: { .connected },
            isActive: { true },
            activate: {}
        ))

        coordinator.setExpanded(true, for: key)
        var requestedInterval = await recorder.first
        while requestedInterval == nil {
            await Task.yield()
            requestedInterval = await recorder.first
        }

        #expect(requestedInterval! >= .milliseconds(500))
        coordinator.setMode(.off)
    }

    @Test("Live to Efficient final-captures before unparking")
    func liveToEfficientFinalCaptureOrder() async {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.events.removeAll()

        harness.coordinator.setMode(.efficient)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.events == [
            "capture:0",
            "unpark:0",
        ])
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test("Off clears frames, slots, timers, and parking")
    func offClearsAllRuntimeState() async {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.refreshLivePreviews()
        await harness.coordinator.waitForPendingWork()

        harness.coordinator.setMode(.off)

        #expect(harness.unparks == [presentation.key])
        #expect(harness.budget.granted.isEmpty)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame == nil
        )
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.capturedAt == nil
        )
    }

    @Test(
        "Leaving Off restores connected preview state",
        arguments: [SessionPreviewMode.efficient, .live]
    )
    func leavingOffRestoresConnectedState(mode: SessionPreviewMode) {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setMode(.off)

        harness.coordinator.setMode(mode)

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.placeholder
                == .awaitingFirstFrame
        )
    }

    @Test(
        "Leaving Off restores disconnected preview state",
        arguments: [SessionPreviewMode.efficient, .live]
    )
    func leavingOffRestoresDisconnectedState(mode: SessionPreviewMode) {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.setConnection(
            .disconnected(reason: "transport ended"),
            for: presentation.key
        )
        harness.coordinator.presentationDidChange(presentation.key)
        harness.coordinator.setMode(.off)

        harness.coordinator.setMode(mode)

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.placeholder
                == .disconnected
        )
    }

    @Test(
        "Leaving Off restores unavailable preview state",
        arguments: [SessionPreviewMode.efficient, .live]
    )
    func leavingOffRestoresUnavailableState(mode: SessionPreviewMode) {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(
            presentation,
            identityIsUnavailable: true
        )
        harness.coordinator.setMode(.off)

        harness.coordinator.setMode(mode)

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.placeholder
                == .unavailable
        )
    }

    @Test("Presentation changes preserve unavailable preview state")
    func presentationChangePreservesUnavailableState() {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(
            presentation,
            identityIsUnavailable: true
        )

        harness.coordinator.presentationDidChange(presentation.key)

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.placeholder
                == .unavailable
        )
    }

    @Test("Efficient captures an expanded active preview when leaving Off")
    func efficientCapturesExpandedActivePreviewAfterOff() async {
        let harness = PreviewCoordinatorHarness(mode: .off)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)

        harness.coordinator.setMode(.efficient)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key])
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test("Efficient retries an Off transition capture when the sidebar appears")
    func efficientRetriesOffCaptureAfterSidebarReveal() async {
        let harness = PreviewCoordinatorHarness(mode: .off)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.coordinator.setSidebarVisible(false)
        harness.coordinator.setMode(.efficient)

        harness.coordinator.setSidebarVisible(true)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key])
    }

    @Test("Efficient retries an Off transition capture when the app activates")
    func efficientRetriesOffCaptureAfterApplicationActivation() async {
        let harness = PreviewCoordinatorHarness(mode: .off)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.coordinator.applicationDidResignActive()
        harness.coordinator.setMode(.efficient)

        harness.coordinator.applicationDidBecomeActive()
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key])
    }

    @Test(
        "Efficient retries an expansion capture when eligibility returns",
        arguments: EfficientExpansionDeferral.allCases
    )
    func efficientRetriesExpandedCapture(
        deferral: EfficientExpansionDeferral
    ) async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        switch deferral {
        case .sidebarHidden:
            harness.coordinator.setSidebarVisible(false)
        case .applicationInactive:
            harness.coordinator.applicationDidResignActive()
        }

        harness.coordinator.setExpanded(true, for: presentation.key)
        #expect(harness.captures.isEmpty)

        switch deferral {
        case .sidebarHidden:
            harness.coordinator.setSidebarVisible(true)
        case .applicationInactive:
            harness.coordinator.applicationDidBecomeActive()
        }
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key])
    }

    @Test("Efficient retries an interrupted capture after sidebar reveal")
    func efficientRetriesInterruptedCaptureAfterSidebarReveal() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        harness.suspendCaptures = true
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.waitUntilCaptureSuspends()

        harness.coordinator.setSidebarVisible(false)
        harness.coordinator.setSidebarVisible(true)
        for _ in 0 ..< 100 where harness.captures.count < 2 {
            await Task.yield()
        }

        #expect(harness.captures == [presentation.key, presentation.key])
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()
    }

    @Test("Efficient retries an interrupted capture after app activation")
    func efficientRetriesInterruptedCaptureAfterApplicationActivation() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        harness.suspendCaptures = true
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.waitUntilCaptureSuspends()

        harness.coordinator.applicationDidResignActive()
        harness.coordinator.applicationDidBecomeActive()
        for _ in 0 ..< 100 where harness.captures.count < 2 {
            await Task.yield()
        }

        #expect(harness.captures == [presentation.key, presentation.key])
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()
    }

    @Test("capture failure preserves the last valid frame")
    func captureFailurePreservesFrame() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.waitForPendingWork()
        let capturedAt = harness.coordinator.viewState(
            for: presentation.key
        )?.capturedAt
        harness.captureShouldFail = true

        harness.coordinator.captureActiveIfNeeded(presentation.key)
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.capturedAt
                == capturedAt
        )
    }

    @Test("navigation-away capture can finish after the session becomes inactive")
    func navigationAwayCaptureSurvivesDeactivation() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.waitForPendingWork()
        harness.captures.removeAll()
        harness.suspendCaptures = true

        harness.coordinator.captureBeforeDeactivation(presentation.key)
        await harness.waitUntilCaptureSuspends()
        harness.setActive(false, for: presentation.key)
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key])
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test("Efficient captures a collapsed active session on navigation away")
    func efficientCapturesCollapsedActiveSessionOnNavigationAway() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)

        harness.coordinator.captureBeforeDeactivation(presentation.key)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key])
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test("Efficient retries navigation capture after identity resolves")
    func efficientRetriesNavigationCaptureAfterIdentityResolution() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "session-0",
            socketName: nil
        )
        let handleID = UUID()
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let pendingPresentation = TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { handleID },
            generation: { nil },
            identity: { nil },
            connectionState: { .connected },
            isActive: { true },
            activate: {},
            refreshIdentity: { nil }
        )
        let resolvedPresentation = TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { handleID },
            generation: { nil },
            identity: { identity },
            connectionState: { .connected },
            isActive: { false },
            activate: {},
            refreshIdentity: { identity }
        )
        harness.coordinator.register(
            pendingPresentation,
            identityIsResolved: false
        )

        harness.coordinator.captureBeforeDeactivation(key)
        harness.coordinator.register(
            resolvedPresentation,
            identityIsResolved: true
        )
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [key])
        #expect(harness.coordinator.viewState(for: key)?.frame != nil)
    }

    @Test("Deferred identity capture starts after deactivation finishes")
    func deferredIdentityCaptureStartsAfterDeactivation() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "session-0",
            socketName: nil
        )
        let handleID = UUID()
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        var isActive = false
        var resolveIdentity: (() -> Void)?
        let pendingPresentation = TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { handleID },
            generation: { nil },
            identity: { nil },
            connectionState: { .connected },
            isActive: { isActive },
            activate: {},
            ensureIdentity: { resolveIdentity?() },
            refreshIdentity: { nil }
        )
        let resolvedPresentation = TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { handleID },
            generation: { nil },
            identity: { identity },
            connectionState: { .connected },
            isActive: { isActive },
            activate: {},
            refreshIdentity: { identity }
        )
        harness.coordinator.register(
            pendingPresentation,
            identityIsResolved: false
        )
        isActive = true
        resolveIdentity = {
            isActive = false
            harness.coordinator.register(
                resolvedPresentation,
                identityIsResolved: true
            )
        }

        harness.coordinator.captureBeforeDeactivation(key) {
            harness.coordinator.presentationDidChange(key)
        }
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [key])
        #expect(harness.coordinator.viewState(for: key)?.frame != nil)
    }

    @Test(
        "Deferred navigation capture clears when identity cannot be reused",
        arguments: DeferredNavigationDisposition.allCases
    )
    func deferredNavigationCaptureClears(
        disposition: DeferredNavigationDisposition
    ) async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "session-0",
            socketName: nil
        )
        let handleID = UUID()
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$1",
            createdAt: "1000"
        )
        let pendingPresentation = TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { handleID },
            generation: { nil },
            identity: { nil },
            connectionState: { .connected },
            isActive: { true },
            activate: {},
            refreshIdentity: { nil }
        )
        let resolvedPresentation = TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { handleID },
            generation: { nil },
            identity: { identity },
            connectionState: { .connected },
            isActive: { false },
            activate: {},
            refreshIdentity: { identity }
        )
        harness.coordinator.register(
            pendingPresentation,
            identityIsResolved: false
        )
        harness.coordinator.captureBeforeDeactivation(key)

        switch disposition {
        case .close:
            harness.coordinator.remove(key, reason: .close)
        case .replacement:
            harness.coordinator.remove(key, reason: .replacement)
        case .unavailable:
            harness.coordinator.register(
                pendingPresentation,
                identityIsResolved: false,
                identityIsUnavailable: true
            )
        }
        harness.coordinator.register(
            resolvedPresentation,
            identityIsResolved: true
        )
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures.isEmpty)
    }

    @Test("Efficient captures navigation away while the sidebar is hidden")
    func efficientCapturesNavigationAwayWithHiddenSidebar() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setSidebarVisible(false)

        harness.coordinator.captureBeforeDeactivation(presentation.key)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key])
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test("Revealing the sidebar preserves a hidden final capture")
    func sidebarRevealPreservesHiddenNavigationCapture() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        harness.suspendCaptures = true
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setSidebarVisible(false)
        harness.coordinator.captureBeforeDeactivation(presentation.key)
        await harness.waitUntilCaptureSuspends()
        harness.setActive(false, for: presentation.key)

        harness.coordinator.setSidebarVisible(true)
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test("Efficient resolves identity for a collapsed active session")
    func efficientResolvesCollapsedActiveIdentity() {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "unresolved",
            socketName: nil
        )
        var identityRequests = 0
        harness.coordinator.register(.init(
            key: key,
            surface: { nil },
            handleID: { UUID() },
            generation: { "generation" },
            identity: { nil },
            connectionState: { .connected },
            isActive: { true },
            activate: {},
            ensureIdentity: { identityRequests += 1 }
        ), identityIsResolved: false)

        #expect(identityRequests == 1)
    }

    @Test("navigation-away capture replaces an in-flight scheduled capture")
    func navigationAwayReplacesScheduledCapture() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        harness.suspendCaptures = true
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.waitUntilCaptureSuspends(count: 1)
        var didCompleteNavigationCapture = false

        harness.coordinator.captureBeforeDeactivation(
            presentation.key,
            completion: { didCompleteNavigationCapture = true }
        )
        await harness.waitUntilCaptureSuspends(count: 2)
        harness.setActive(false, for: presentation.key)
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key, presentation.key])
        #expect(didCompleteNavigationCapture)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test(
        "Efficient retries a navigation capture after eligibility invalidation",
        arguments: NavigationCaptureInvalidation.allCases
    )
    func efficientRetriesNavigationCaptureAfterEligibilityInvalidation(
        invalidation: NavigationCaptureInvalidation
    ) async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.waitForPendingWork()
        harness.captures.removeAll()
        harness.suspendCaptures = true
        var didFinishDeactivation = false

        harness.coordinator.captureBeforeDeactivation(
            presentation.key,
            completion: {
                didFinishDeactivation = true
                harness.coordinator.finishDeactivation(presentation.key)
            }
        )
        await harness.waitUntilCaptureSuspends()
        harness.setActive(false, for: presentation.key)
        switch invalidation {
        case .collapse:
            harness.coordinator.setExpanded(false, for: presentation.key)
        case .sidebarHidden:
            harness.coordinator.setSidebarVisible(false)
            harness.coordinator.setSidebarVisible(true)
        case .applicationInactive:
            harness.coordinator.applicationDidResignActive()
            harness.coordinator.applicationDidBecomeActive()
        }
        for _ in 0 ..< 100 where harness.captures.count < 2 {
            await Task.yield()
        }
        let captureAttempts = harness.captures
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()

        #expect(captureAttempts == [presentation.key, presentation.key])
        #expect(didFinishDeactivation)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame != nil
        )
    }

    @Test("sidebar hiding releases parking but app deactivation retains it")
    func visibilityReleasesAndApplicationDeactivationRetainsParking() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)

        harness.coordinator.setSidebarVisible(false)
        #expect(harness.unparks == [presentation.key])
        #expect(harness.budget.granted.isEmpty)

        harness.coordinator.setSidebarVisible(true)
        harness.unparks.removeAll()
        harness.coordinator.applicationDidResignActive()
        #expect(harness.parks == [presentation.key])
        #expect(harness.unparks.isEmpty)
        #expect(harness.budget.granted.count == 1)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.isLive
                == false
        )

        harness.coordinator.applicationDidBecomeActive()
        #expect(harness.parks == [presentation.key])
        #expect(harness.unparks.isEmpty)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.isLive
                == true
        )
    }

    @Test("non-key app reactivation releases retained preview budget")
    func nonKeyApplicationReactivationReleasesParking() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.coordinator.applicationDidResignActive()
        #expect(harness.parks == [presentation.key])
        #expect(harness.budget.granted.count == 1)

        harness.keyWindow = false
        harness.coordinator.applicationDidBecomeActive()

        #expect(harness.parks.isEmpty)
        #expect(harness.unparks == [presentation.key])
        #expect(harness.budget.granted.isEmpty)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.isLive
                == false
        )
    }

    @Test("removed Always Live rows can clear expansion before re-registering")
    func removedAlwaysLiveRowsClearExpansion() async {
        let harness = PreviewCoordinatorHarness(mode: .alwaysLive)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        #expect(harness.parks == [presentation.key])

        harness.coordinator.remove(presentation.key, reason: .replacement)
        harness.coordinator.setExpanded(false, for: presentation.key)
        harness.coordinator.register(presentation)
        await harness.coordinator.refreshLivePreviews()

        #expect(harness.parks.isEmpty)
        #expect(harness.captures.isEmpty)
    }

    @Test("non-key scenes release and reacquire parked preview budget")
    func nonKeySceneReleasesParkedPreviewBudget() async {
        let harness = PreviewCoordinatorHarness(
            mode: .live,
            activationDelay: .milliseconds(20)
        )
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        #expect(harness.parks == [presentation.key])
        #expect(harness.budget.granted.count == 1)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.isLive
                == true
        )

        harness.keyWindow = false
        harness.coordinator.sceneWindowFocusDidChange(isKey: false)

        #expect(harness.parks.isEmpty)
        #expect(harness.unparks == [presentation.key])
        #expect(harness.budget.granted.isEmpty)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.isLive
                == false
        )

        harness.keyWindow = true
        harness.coordinator.sceneWindowFocusDidChange(isKey: true)
        await waitUntilMainActor {
            harness.parks == [presentation.key]
        }

        #expect(harness.parks == [presentation.key])
        #expect(harness.budget.granted.count == 1)
    }

    @Test("reconnect releases parking without immediately reacquiring it")
    func reconnectDoesNotReparkStaleSurface() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        #expect(harness.parks == [presentation.key])

        harness.coordinator.remove(presentation.key, reason: .reconnect)

        #expect(harness.parks.isEmpty)
        #expect(harness.budget.granted.isEmpty)
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.placeholder
                == .reconnecting
        )
    }

    @Test("resolved reconnect without a frame awaits its first capture")
    func resolvedReconnectWithoutFrameAwaitsFirstCapture() {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.setConnection(
            .disconnected(reason: "transport ended"),
            for: presentation.key
        )
        harness.coordinator.presentationDidChange(presentation.key)
        harness.coordinator.remove(presentation.key, reason: .reconnect)
        harness.setConnection(.connected, for: presentation.key)

        harness.coordinator.register(presentation, identityIsResolved: true)

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.placeholder
                == .awaitingFirstFrame
        )
    }

    @Test("replacement preserves expansion for the same preview key")
    func replacementPreservesExpansion() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.waitForPendingWork()
        harness.captures.removeAll()
        let viewModel = harness.coordinator.viewModel(for: presentation.key)

        harness.coordinator.remove(presentation.key, reason: .replacement)
        harness.coordinator.register(presentation)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [presentation.key])
        #expect(
            harness.coordinator.viewModel(for: presentation.key) === viewModel
        )
    }

    @Test("removing the parking host cannot repark during slot release")
    func parkingHostRemovalDoesNotRepark() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        let host = LivePreviewParkingHost(frame: .zero)
        harness.coordinator.installParkingHost(host)
        #expect(harness.parks == [presentation.key])

        harness.coordinator.removeParkingHost(host)

        #expect(harness.parks.isEmpty)
        #expect(harness.budget.granted.isEmpty)
    }

    @Test("parking failure waits for a presentation lifecycle change")
    func parkingFailureDoesNotRecurse() async {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.parkShouldFail = true
        harness.coordinator.register(presentation)

        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.refreshLivePreviews()

        #expect(harness.parkAttempts == 1)
        #expect(harness.budget.granted.isEmpty)

        harness.parkShouldFail = false
        harness.coordinator.presentationDidChange(presentation.key)

        #expect(harness.parkAttempts == 2)
        #expect(harness.parks == [presentation.key])
    }

    @Test("shutdown releases parked surfaces and the scene budget")
    func shutdownReleasesPreviewResources() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)

        harness.coordinator.shutdown()

        #expect(harness.unparks == [presentation.key])
        #expect(harness.budget.granted.isEmpty)
        #expect(harness.coordinator.viewState(for: presentation.key) == nil)
    }

    @Test("activation delay cannot repark after the app resigns")
    func activationDelayRevalidatesActivity() async {
        let harness = PreviewCoordinatorHarness(
            mode: .live,
            activationDelay: .milliseconds(20)
        )
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.applicationDidResignActive()
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)

        harness.coordinator.applicationDidBecomeActive()
        harness.coordinator.applicationDidResignActive()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(harness.parks.isEmpty)
        #expect(harness.budget.granted.isEmpty)
    }

    @Test("activation waits for the delay and key-window revalidation")
    func activationDelayRevalidatesKeyWindow() async {
        let harness = PreviewCoordinatorHarness(
            mode: .live,
            activationDelay: .milliseconds(20)
        )
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.applicationDidResignActive()
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.keyWindow = false

        harness.coordinator.applicationDidBecomeActive()
        #expect(harness.parks.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.parks.isEmpty)

        harness.coordinator.applicationDidResignActive()
        harness.keyWindow = true
        harness.coordinator.applicationDidBecomeActive()
        #expect(harness.parks.isEmpty)
        await waitUntilMainActor {
            harness.parks == [presentation.key]
        }
        #expect(harness.parks == [presentation.key])
    }

    @Test("a scene becoming key resumes delayed live parking")
    func keyWindowChangeRestartsLiveParking() async {
        let harness = PreviewCoordinatorHarness(
            mode: .live,
            activationDelay: .milliseconds(20)
        )
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.applicationDidResignActive()
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.keyWindow = false
        harness.coordinator.applicationDidBecomeActive()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.parks.isEmpty)

        harness.keyWindow = true
        harness.coordinator.sceneWindowFocusDidChange(isKey: true)
        await waitUntilMainActor {
            harness.parks == [presentation.key]
        }

        #expect(harness.parks == [presentation.key])
    }

    @Test("non-Live modes schedule no work during activation")
    func nonLiveActivationSchedulesNoWork() async {
        let recorder = PreviewIntervalRecorder()
        let coordinator = TmuxSessionPreviewCoordinator(
            mode: .off,
            budget: LivePreviewBudget(limit: 4),
            capture: { _, _ in nil },
            park: { _ in },
            unpark: { _ in },
            isKeyWindow: { true },
            sleep: { duration in
                await recorder.record(duration)
            }
        )

        for mode in [SessionPreviewMode.off, .efficient] {
            coordinator.setMode(mode)
            coordinator.applicationDidResignActive()
            coordinator.applicationDidBecomeActive()
            coordinator.sceneWindowFocusDidChange(isKey: true)
            for _ in 0 ..< 10 {
                await Task.yield()
            }
        }

        #expect(await recorder.count == 0)
    }

    @Test("Live coalesces activation parking work for the key scene")
    func liveActivationCoalescesParkingWork() async {
        let recorder = PreviewIntervalRecorder()
        let coordinator = TmuxSessionPreviewCoordinator(
            mode: .live,
            budget: LivePreviewBudget(limit: 4),
            capture: { _, _ in nil },
            park: { _ in },
            unpark: { _ in },
            isKeyWindow: { true },
            sleep: { duration in
                await recorder.record(duration)
            }
        )
        coordinator.applicationDidResignActive()

        coordinator.applicationDidBecomeActive()
        coordinator.sceneWindowFocusDidChange(isKey: true)
        coordinator.sceneWindowFocusDidChange(isKey: true)
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(await recorder.count == 1)
    }

    @Test("activation parks one terminal surface per main-thread turn")
    func activationParksIncrementally() async {
        let harness = PreviewCoordinatorHarness(
            mode: .alwaysLive,
            activationDelay: .zero,
            parkingInterval: .seconds(60)
        )
        let presentations = (0 ..< 3).map {
            harness.presentation(index: $0, isActive: false)
        }
        harness.coordinator.applicationDidResignActive()
        for presentation in presentations {
            harness.coordinator.register(presentation)
            harness.coordinator.setExpanded(true, for: presentation.key)
        }

        harness.coordinator.applicationDidBecomeActive()
        await waitUntilMainActor { harness.parks.count == 1 }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(harness.parks.count == 1)
        harness.coordinator.applicationDidResignActive()
    }

    @Test("invalidating a suspended capture prevents stale publication")
    func suspendedCaptureCannotPublishAfterOff() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        harness.suspendCaptures = true
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.waitUntilCaptureSuspends()

        harness.coordinator.setMode(.off)
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame == nil
        )
    }

    @Test(arguments: PreviewInvalidation.allCases)
    func everyEligibilityTransitionInvalidatesSuspendedCapture(
        invalidation: PreviewInvalidation
    ) async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        harness.suspendCaptures = true
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.waitUntilCaptureSuspends()

        switch invalidation {
        case .off:
            harness.coordinator.setMode(.off)
        case .collapse:
            harness.coordinator.setExpanded(false, for: presentation.key)
        case .sidebarHidden:
            harness.coordinator.setSidebarVisible(false)
        case .deactivated:
            harness.coordinator.applicationDidResignActive()
        case .reconnect:
            harness.coordinator.remove(presentation.key, reason: .reconnect)
        case .replacement:
            harness.coordinator.remove(presentation.key, reason: .replacement)
        case .close:
            harness.coordinator.remove(presentation.key, reason: .close)
        }
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame == nil
        )
    }

    @Test("grant revocation invalidates a suspended parked capture")
    func grantRevocationInvalidatesCapture() async {
        let harness = PreviewCoordinatorHarness(mode: .live)
        harness.suspendCaptures = true
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.refreshLivePreviews()
        await harness.waitUntilCaptureSuspends()

        harness.budget.release(LivePreviewRequestID(
            sceneID: harness.coordinator.sceneID,
            presentation: presentation.key
        ))
        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame == nil
        )
    }

    @Test("a client session switch rejects newly captured pixels")
    func switchedClientIdentityRejectsCapture() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.setRefreshedIdentity(
            TmuxSessionIdentity(
                serverPID: "101",
                sessionID: "$99",
                createdAt: "9000"
            ),
            for: presentation.key
        )
        harness.coordinator.register(presentation)

        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame == nil
        )
    }

    @Test("activation handoff does not wait for preview capture")
    func activationHandoffAvoidsCapture() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.events.removeAll()

        harness.coordinator.prepareToActivate(presentation.key)

        #expect(harness.events == [
            "unpark:0",
            "activate:0",
        ])
        #expect(harness.budget.granted.isEmpty)
    }

    @Test("Live parks an outgoing presentation after its final capture")
    func liveHandoffDefersOutgoingParking() async {
        let harness = PreviewCoordinatorHarness(mode: .live)
        harness.suspendCaptures = true
        harness.parkShouldFail = true
        let outgoing = harness.presentation(index: 0, isActive: true)
        let incoming = harness.presentation(index: 1, isActive: false)
        harness.coordinator.register(outgoing)
        harness.coordinator.register(incoming)
        harness.coordinator.setExpanded(true, for: outgoing.key)

        harness.coordinator.prepareToActivate(incoming.key) {
            harness.coordinator.captureBeforeDeactivation(outgoing.key) {
                harness.parkShouldFail = false
                harness.coordinator.finishDeactivation(outgoing.key)
            }
            harness.setActive(false, for: outgoing.key)
            harness.setActive(true, for: incoming.key)
        }
        await harness.waitUntilCaptureSuspends()

        #expect(harness.parkAttempts == 0)

        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()

        #expect(harness.parkAttempts == 1)
        #expect(harness.parks == [outgoing.key])
    }

    @Test("Off activation bypasses preview state work")
    func offActivationBypassesPreviewStateWork() {
        let harness = PreviewCoordinatorHarness(mode: .off)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.events.removeAll()
        var publications = 0
        let observation = harness.coordinator
            .viewModel(for: presentation.key).$state
            .dropFirst()
            .sink { _ in publications += 1 }

        harness.coordinator.prepareToActivate(presentation.key)

        #expect(harness.events == ["activate:0"])
        #expect(publications == 0)
        withExtendedLifetime(observation) {}
    }

    @Test("one live frame does not publish sibling tile state")
    func liveFramePublicationIsTileScoped() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let active = harness.presentation(index: 0, isActive: true)
        let sibling = harness.presentation(index: 1, isActive: false)
        harness.coordinator.register(active)
        harness.coordinator.register(sibling)
        var siblingPublications = 0
        let observation = harness.coordinator.viewModel(for: sibling.key)
            .$state.dropFirst()
            .sink { _ in siblingPublications += 1 }

        harness.coordinator.setExpanded(true, for: active.key)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.captures == [active.key])
        #expect(siblingPublications == 0)
        withExtendedLifetime(observation) {}
    }

    @Test("unchanged preview state does not republish its tile")
    func unchangedPreviewStateIsNotRepublished() {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        var publications = 0
        let observation = harness.coordinator
            .viewModel(for: presentation.key).$state
            .dropFirst()
            .sink { _ in publications += 1 }

        harness.coordinator.register(presentation)

        #expect(publications == 0)
        withExtendedLifetime(observation) {}
    }

    @Test("activation callback cannot cancel its own handoff fence")
    func activationCallbackPreservesHandoffFence() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.events.removeAll()

        harness.coordinator.prepareToActivate(presentation.key) {
            harness.coordinator.cancelPendingActivation()
            harness.events.append("activate:0")
            harness.setActive(true, for: presentation.key)
        }

        #expect(harness.events == [
            "unpark:0",
            "activate:0",
        ])
        #expect(harness.parks.isEmpty)
        #expect(harness.budget.granted.isEmpty)
    }

    @Test("a suspended Live capture cannot delay activation")
    func suspendedLiveCaptureDoesNotDelayActivation() async {
        let harness = PreviewCoordinatorHarness(mode: .live)
        harness.suspendCaptures = true
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.refreshLivePreviews()
        await harness.waitUntilCaptureSuspends()
        harness.events.removeAll()

        harness.coordinator.prepareToActivate(presentation.key)

        #expect(harness.events == [
            "unpark:0",
            "activate:0",
        ])
        #expect(harness.parks.isEmpty)

        harness.resumeCapture()
        await harness.coordinator.waitForPendingWork()
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.frame == nil
        )
    }

    @Test("disconnected presentations are placeholders, not live previews")
    func disconnectedPresentationIsNotLive() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)

        harness.setConnection(
            .disconnected(reason: "transport ended"),
            for: presentation.key
        )
        harness.coordinator.presentationDidChange(presentation.key)

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.placeholder
                == .disconnected
        )
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.isLive
                == false
        )
    }

    @Test("scene model owns the coordinator and forwards mode and activity")
    func sceneModelIntegration() async throws {
        let workspace = try seededWorkspace()
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let mode = CurrentValueSubject<SessionPreviewMode, Never>(.off)
        let model = try makeModel(
            database: workspace.database,
            localHostID: workspace.hostID,
            sessionPreviewCoordinator: harness.coordinator,
            sessionPreviewModePublisher: mode.eraseToAnyPublisher()
        )
        await waitUntilMainActor {
            harness.coordinator.mode == .off
        }
        mode.send(.live)
        await waitUntilMainActor {
            harness.coordinator.mode == .live
        }
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        #expect(model.tmuxSessionPreviewCoordinator === harness.coordinator)
        #expect(harness.parks == [presentation.key])

        model.handleApplicationDidResignActiveForResourceMonitoring()

        #expect(harness.parks == [presentation.key])
        #expect(harness.budget.granted.count == 1)
    }

    @Test("will-resign activity reaches previews before window focus loss")
    func applicationResignationPrecedesWindowFocusLoss() async throws {
        let workspace = try seededWorkspace()
        let harness = PreviewCoordinatorHarness(mode: .live)
        let model = try makeModel(
            database: workspace.database,
            localHostID: workspace.hostID,
            sessionPreviewCoordinator: harness.coordinator
        )
        model.subscribeAppActivity()
        model.isFocusedWindow = true
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        #expect(harness.parks == [presentation.key])

        NotificationCenter.default.post(
            name: NSApplication.willResignActiveNotification,
            object: NSApp
        )
        #expect(model.isAppActive == false)
        model.isFocusedWindow = false

        #expect(harness.parks == [presentation.key])
        #expect(harness.unparks.isEmpty)
        #expect(harness.budget.granted.count == 1)
        await model.shutdown()
    }

    @Test("rapid activation and resignation preserve inactive state")
    func rapidApplicationActivityPreservesLatestState() async throws {
        let workspace = try seededWorkspace()
        let model = try makeModel(
            database: workspace.database,
            localHostID: workspace.hostID
        )
        model.subscribeAppActivity()

        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        NotificationCenter.default.post(
            name: NSApplication.willResignActiveNotification,
            object: NSApp
        )
        try await Task.sleep(for: .milliseconds(20))

        #expect(model.isAppActive == false)
        await model.shutdown()
    }
}

@MainActor
private final class PreviewCoordinatorHarness {
    enum CaptureFailure: Error { case expected }

    let budget: LivePreviewBudget
    private(set) lazy var coordinator = TmuxSessionPreviewCoordinator(
        sceneID: UUID(),
        mode: initialMode,
        budget: budget,
        capture: { [weak self] presentation, _ in
            guard let self else { throw CaptureFailure.expected }
            captures.append(presentation.key)
            events.append("capture:\(Self.index(of: presentation))")
            if captureShouldFail {
                throw CaptureFailure.expected
            }
            if suspendCaptures {
                await withCheckedContinuation { continuation in
                    captureContinuations.append(continuation)
                }
            }
            captureSequence &+= 1
            return try makePreviewSnapshot(
                surfaceID: UInt32(Self.index(of: presentation) + 1),
                seed: captureSequence
            )
        },
        park: { [weak self] presentation in
            guard let self else { return }
            parkAttempts += 1
            if parkShouldFail {
                throw CaptureFailure.expected
            }
            parks.insert(presentation.key)
            events.append("park:\(Self.index(of: presentation))")
        },
        unpark: { [weak self] presentation in
            self?.parks.remove(presentation.key)
            self?.unparks.append(presentation.key)
            self?.events.append("unpark:\(Self.index(of: presentation))")
        },
        isKeyWindow: { [weak self] in self?.keyWindow == true },
        sleep: { duration in try await Task.sleep(for: duration) },
        activationDelay: activationDelay,
        parkingInterval: parkingInterval,
        liveInterval: .seconds(60)
    )

    private let initialMode: SessionPreviewMode
    private let activationDelay: Duration
    private let parkingInterval: Duration
    var captures: [TmuxPreviewKey] = []
    var parks: Set<TmuxPreviewKey> = []
    var unparks: [TmuxPreviewKey] = []
    var events: [String] = []
    var captureShouldFail = false
    var suspendCaptures = false
    var keyWindow = true
    var parkShouldFail = false
    var parkAttempts = 0
    var identityRefreshes = 0
    private var captureContinuations: [CheckedContinuation<Void, Never>] = []
    private var captureSequence: UInt32 = 0
    private var activeByKey: [TmuxPreviewKey: Bool] = [:]
    private var connectionByKey: [TmuxPreviewKey: ConnectionState] = [:]
    private var identityByKey: [TmuxPreviewKey: TmuxSessionIdentity] = [:]
    private var refreshedIdentityByKey:
        [TmuxPreviewKey: TmuxSessionIdentity?] = [:]

    init(
        mode: SessionPreviewMode,
        budgetLimit: Int = 4,
        activationDelay: Duration = .milliseconds(250),
        parkingInterval: Duration = .milliseconds(10)
    ) {
        initialMode = mode
        budget = LivePreviewBudget(limit: budgetLimit)
        self.activationDelay = activationDelay
        self.parkingInterval = parkingInterval
    }

    func presentation(
        index: Int,
        isActive: Bool
    ) -> TmuxSessionPreviewCoordinator.Presentation {
        let key = TmuxPreviewKey(
            hostID: UUID(),
            name: "session-\(index)",
            socketName: nil
        )
        activeByKey[key] = isActive
        connectionByKey[key] = .connected
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$\(index)",
            createdAt: "1000"
        )
        identityByKey[key] = identity
        return TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")! },
            generation: { "generation-\(index)" },
            identity: { identity },
            connectionState: { [weak self] in self?.connectionByKey[key] },
            isActive: { [weak self] in self?.activeByKey[key] == true },
            activate: { [weak self] in
                self?.events.append("activate:\(index)")
                self?.activeByKey[key] = true
            },
            refreshIdentity: { [weak self] in
                guard let self else { return nil }
                identityRefreshes += 1
                if let refreshed = refreshedIdentityByKey[key] {
                    return refreshed
                }
                return identityByKey[key]
            }
        )
    }

    func waitUntilCaptureSuspends(count: Int = 1) async {
        while captureContinuations.count < count {
            await Task.yield()
        }
    }

    func resumeCapture() {
        let continuations = captureContinuations
        captureContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func setActive(_ active: Bool, for key: TmuxPreviewKey) {
        activeByKey[key] = active
    }

    func setConnection(_ state: ConnectionState, for key: TmuxPreviewKey) {
        connectionByKey[key] = state
    }

    func setRefreshedIdentity(
        _ identity: TmuxSessionIdentity?,
        for key: TmuxPreviewKey
    ) {
        refreshedIdentityByKey.updateValue(identity, forKey: key)
    }

    private static func index(
        of presentation: TmuxSessionPreviewCoordinator.Presentation
    ) -> Int {
        Int(presentation.key.name.split(separator: "-").last!)!
    }
}

enum PreviewInvalidation: CaseIterable, Sendable {
    case off
    case collapse
    case sidebarHidden
    case deactivated
    case reconnect
    case replacement
    case close
}

enum DeferredNavigationDisposition: CaseIterable, Sendable {
    case close
    case replacement
    case unavailable
}

enum EfficientExpansionDeferral: CaseIterable, Sendable {
    case sidebarHidden
    case applicationInactive
}

enum NavigationCaptureInvalidation: CaseIterable, Sendable {
    case collapse
    case sidebarHidden
    case applicationInactive
}

private actor PreviewIntervalRecorder {
    private var intervals: [Duration] = []

    var first: Duration? { intervals.first }
    var count: Int { intervals.count }

    func record(_ duration: Duration) {
        intervals.append(duration)
    }
}
