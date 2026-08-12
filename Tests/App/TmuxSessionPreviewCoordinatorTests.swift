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
        [active, granted, waiting].forEach(harness.coordinator.register)
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
            harness.coordinator.viewState(for: presentation.key)?.image != nil
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
            harness.coordinator.viewState(for: presentation.key)?.image == nil
        )
        #expect(
            harness.coordinator.viewState(for: presentation.key)?.capturedAt == nil
        )
    }

    @Test("capture failure preserves the last valid frame")
    func captureFailurePreservesFrame() async {
        let harness = PreviewCoordinatorHarness(mode: .efficient)
        let presentation = harness.presentation(index: 0, isActive: true)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        await harness.coordinator.waitForPendingWork()
        let image = harness.coordinator.viewState(for: presentation.key)?.image
        harness.captureShouldFail = true

        harness.coordinator.captureActiveIfNeeded(presentation.key)
        await harness.coordinator.waitForPendingWork()

        #expect(
            harness.coordinator.viewState(for: presentation.key)?.image === image
        )
    }

    @Test("sidebar hiding and app deactivation release only this scene")
    func visibilityAndActivityReleaseScene() {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)

        harness.coordinator.setSidebarVisible(false)
        #expect(harness.unparks == [presentation.key])
        #expect(harness.budget.granted.isEmpty)

        harness.coordinator.setSidebarVisible(true)
        harness.coordinator.applicationDidResignActive()
        #expect(harness.budget.granted.isEmpty)
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

    @Test("activation delay cannot repark after the app resigns")
    func activationDelayRevalidatesActivity() async {
        let harness = PreviewCoordinatorHarness(
            mode: .live,
            activationDelay: .milliseconds(20)
        )
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.coordinator.applicationDidResignActive()
        harness.parks.removeAll()

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
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.coordinator.applicationDidResignActive()
        harness.parks.removeAll()
        harness.keyWindow = false

        harness.coordinator.applicationDidBecomeActive()
        #expect(harness.parks.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.parks.isEmpty)

        harness.coordinator.applicationDidResignActive()
        harness.keyWindow = true
        harness.coordinator.applicationDidBecomeActive()
        #expect(harness.parks.isEmpty)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.parks == [presentation.key])
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
            harness.coordinator.viewState(for: presentation.key)?.image == nil
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
            harness.coordinator.viewState(for: presentation.key)?.image == nil
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
            harness.coordinator.viewState(for: presentation.key)?.image == nil
        )
    }

    @Test("activation handoff captures, unparks, releases, then activates")
    func activationHandoffOrder() async {
        let harness = PreviewCoordinatorHarness(mode: .live)
        let presentation = harness.presentation(index: 0, isActive: false)
        harness.coordinator.register(presentation)
        harness.coordinator.setExpanded(true, for: presentation.key)
        harness.events.removeAll()

        harness.coordinator.prepareToActivate(presentation.key)
        await harness.coordinator.waitForPendingWork()

        #expect(harness.events == [
            "capture:0",
            "unpark:0",
            "activate:0",
        ])
        #expect(harness.budget.granted.isEmpty)
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

        #expect(harness.parks.isEmpty)
        #expect(harness.budget.granted.isEmpty)
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
                    captureContinuation = continuation
                }
            }
            captureSequence &+= 1
            return TerminalSurfaceSnapshot(
                image: NSImage(size: CGSize(width: 32, height: 20)),
                captureToken: TerminalSurfaceCaptureToken(
                    surfaceID: UInt32(Self.index(of: presentation) + 1),
                    seed: captureSequence
                )
            )
        },
        park: { [weak self] presentation in
            self?.parks.insert(presentation.key)
            self?.events.append("park:\(Self.index(of: presentation))")
        },
        unpark: { [weak self] presentation in
            self?.parks.remove(presentation.key)
            self?.unparks.append(presentation.key)
            self?.events.append("unpark:\(Self.index(of: presentation))")
        },
        isKeyWindow: { [weak self] in self?.keyWindow == true },
        sleep: { duration in try await Task.sleep(for: duration) },
        activationDelay: activationDelay,
        liveInterval: .seconds(60)
    )

    private let initialMode: SessionPreviewMode
    private let activationDelay: Duration
    var captures: [TmuxPreviewKey] = []
    var parks: Set<TmuxPreviewKey> = []
    var unparks: [TmuxPreviewKey] = []
    var events: [String] = []
    var captureShouldFail = false
    var suspendCaptures = false
    var keyWindow = true
    private var captureContinuation: CheckedContinuation<Void, Never>?
    private var captureSequence: UInt32 = 0
    private var activeByKey: [TmuxPreviewKey: Bool] = [:]

    init(
        mode: SessionPreviewMode,
        budgetLimit: Int = 4,
        activationDelay: Duration = .milliseconds(250)
    ) {
        initialMode = mode
        budget = LivePreviewBudget(limit: budgetLimit)
        self.activationDelay = activationDelay
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
        let identity = TmuxSessionIdentity(
            serverPID: "101",
            sessionID: "$\(index)",
            createdAt: "1000"
        )
        return TmuxSessionPreviewCoordinator.Presentation(
            key: key,
            surface: { nil },
            handleID: { UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")! },
            generation: { "generation-\(index)" },
            identity: { identity },
            connectionState: { .connected },
            isActive: { [weak self] in self?.activeByKey[key] == true },
            activate: { [weak self] in
                self?.events.append("activate:\(index)")
                self?.activeByKey[key] = true
            }
        )
    }

    func waitUntilCaptureSuspends() async {
        while captureContinuation == nil {
            await Task.yield()
        }
    }

    func resumeCapture() {
        captureContinuation?.resume()
        captureContinuation = nil
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

private actor PreviewIntervalRecorder {
    private var intervals: [Duration] = []

    var first: Duration? { intervals.first }

    func record(_ duration: Duration) {
        intervals.append(duration)
    }
}
