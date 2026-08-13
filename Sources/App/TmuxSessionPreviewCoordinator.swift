import AppKit
@preconcurrency import Combine
import Foundation
import GhosthubSettings
import GhosthubTerminal
import GhosthubTmux
import GhosthubTransport

struct TmuxPreviewViewState {
    let image: NSImage?
    let capturedAt: Date?
    let placeholder: TmuxPreviewPlaceholder?
    let connectionState: ConnectionState?
    let isLive: Bool
}

@MainActor
final class TmuxSessionPreviewCoordinator: ObservableObject {
    struct Presentation {
        let key: TmuxPreviewKey
        let surface: () -> TerminalSurfaceView?
        let handleID: () -> UUID?
        let generation: () -> String?
        let identity: @MainActor () -> TmuxSessionIdentity?
        let connectionState: () -> ConnectionState?
        let isActive: () -> Bool
        let activate: () -> Void
        let ensureIdentity: () -> Void
        let refreshIdentity: @MainActor () async -> TmuxSessionIdentity?

        init(
            key: TmuxPreviewKey,
            surface: @escaping () -> TerminalSurfaceView?,
            handleID: @escaping () -> UUID?,
            generation: @escaping () -> String?,
            identity: @escaping @MainActor () -> TmuxSessionIdentity?,
            connectionState: @escaping () -> ConnectionState?,
            isActive: @escaping () -> Bool,
            activate: @escaping () -> Void,
            ensureIdentity: @escaping () -> Void = {},
            refreshIdentity: (@MainActor () async -> TmuxSessionIdentity?)?
                = nil
        ) {
            self.key = key
            self.surface = surface
            self.handleID = handleID
            self.generation = generation
            self.identity = identity
            self.connectionState = connectionState
            self.isActive = isActive
            self.activate = activate
            self.ensureIdentity = ensureIdentity
            if let refreshIdentity {
                self.refreshIdentity = refreshIdentity
            } else {
                self.refreshIdentity = { identity() }
            }
        }
    }

    enum RemovalReason {
        case reconnect
        case close
        case replacement
    }

    typealias Capture = @MainActor (
        _ presentation: Presentation,
        _ previousCaptureToken: TerminalSurfaceCaptureToken?
    ) async throws -> TerminalSurfaceSnapshot?
    typealias Park = @MainActor (_ presentation: Presentation) throws -> Void
    typealias Unpark = @MainActor (_ presentation: Presentation) -> Void
    typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    private struct PresentationVersion: Equatable {
        let handleID: UUID?
        let generation: String?
    }

    private enum CaptureReason {
        case scheduled
        case navigationAway
        case finalBeforeUnpark
    }

    let sceneID: UUID
    @Published private(set) var viewStates: [TmuxPreviewKey: TmuxPreviewViewState] = [:]

    private let budget: LivePreviewBudget
    private let capture: Capture
    private let finalCapture: Capture
    private let injectedPark: Park?
    private let injectedUnpark: Unpark?
    private let injectedIsKeyWindow: (() -> Bool)?
    private let sleep: Sleep
    private let activationDelay: Duration
    private let liveInterval: Duration
    private let now: () -> Date
    private weak var parkingHost: LivePreviewParkingHost?
    private var presentations: [TmuxPreviewKey: Presentation] = [:]
    private var registeredVersions: [TmuxPreviewKey: PresentationVersion] = [:]
    private var previewStates: [TmuxPreviewKey: TmuxSessionPreviewState<NSImage>] = [:]
    private var expandedKeys: Set<TmuxPreviewKey> = []
    private var parkedKeys: Set<TmuxPreviewKey> = []
    private var activatingKeys: Set<TmuxPreviewKey> = []
    private var reconnectingKeys: Set<TmuxPreviewKey> = []
    private var unresolvedIdentityKeys: Set<TmuxPreviewKey> = []
    private var parkingBlockedKeys: Set<TmuxPreviewKey> = []
    private var isParkingHostChanging = false
    private var isShutDown = false
    private var generations: [TmuxPreviewKey: UInt64] = [:]
    private var activeCaptureIDs: [TmuxPreviewKey: UUID] = [:]
    private var pendingTasks: [UUID: Task<Void, Never>] = [:]
    private var liveTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0
    private var isInvokingActivation = false
    private var navigationGeneration: UInt64 = 0
    private var budgetCancellable: AnyCancellable?
    private var lastGranted: Set<LivePreviewRequestID>
    private(set) var mode: SessionPreviewMode
    private var isSidebarVisible = true
    private var isApplicationActive = true

    init(
        sceneID: UUID = UUID(),
        mode: SessionPreviewMode,
        budget: LivePreviewBudget = .shared,
        snapshotter: TerminalSurfaceSnapshotter? = nil,
        capture: Capture? = nil,
        park: Park? = nil,
        unpark: Unpark? = nil,
        isKeyWindow: (() -> Bool)? = nil,
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        activationDelay: Duration = .milliseconds(250),
        liveInterval: Duration = .milliseconds(500),
        now: @escaping () -> Date = Date.init
    ) {
        self.sceneID = sceneID
        self.mode = mode
        self.budget = budget
        let resolvedSnapshotter = snapshotter ?? TerminalSurfaceSnapshotter()
        if let capture {
            self.capture = capture
            finalCapture = capture
        } else {
            self.capture = { presentation, previousCaptureToken in
                guard let surface = presentation.surface() else {
                    throw TerminalSurfaceSnapshotError.missingIOSurface
                }
                return try await resolvedSnapshotter.snapshot(
                    of: surface,
                    outputWidth: 320,
                    previousCaptureToken: previousCaptureToken
                )
            }
            finalCapture = { presentation, previousCaptureToken in
                guard let surface = presentation.surface() else {
                    throw TerminalSurfaceSnapshotError.missingIOSurface
                }
                return try await resolvedSnapshotter.snapshot(
                    of: surface,
                    outputWidth: 320,
                    previousCaptureToken: previousCaptureToken,
                    coalescesInFlight: false
                )
            }
        }
        injectedPark = park
        injectedUnpark = unpark
        injectedIsKeyWindow = isKeyWindow
        self.sleep = sleep
        self.activationDelay = activationDelay
        self.liveInterval = max(liveInterval, .milliseconds(500))
        self.now = now
        lastGranted = budget.granted
        budgetCancellable = budget.$granted
            .removeDuplicates()
            .sink { [weak self] granted in
                self?.budgetGrantsChanged(granted)
            }
    }

    deinit {
        liveTask?.cancel()
        activationTask?.cancel()
        pendingTasks.values.forEach { $0.cancel() }
    }

    func viewState(for key: TmuxPreviewKey) -> TmuxPreviewViewState? {
        viewStates[key]
    }

    func register(
        _ presentation: Presentation,
        identityIsResolved: Bool = true,
        identityIsUnavailable: Bool = false
    ) {
        let key = presentation.key
        guard !isShutDown else { return }
        let version = version(of: presentation)
        if let previous = registeredVersions[key], previous != version,
           !reconnectingKeys.contains(key) {
            previewStates[key]?.clear()
            invalidate(key)
            unparkAndRelease(key)
        }
        presentations[key] = presentation
        registeredVersions[key] = version
        parkingBlockedKeys.remove(key)
        if identityIsResolved || identityIsUnavailable {
            unresolvedIdentityKeys.remove(key)
        } else {
            unresolvedIdentityKeys.insert(key)
        }
        if previewStates[key] == nil {
            previewStates[key] = TmuxSessionPreviewState()
        }
        if identityIsUnavailable {
            unparkAndRelease(key)
            previewStates[key]?.setUnavailable()
        } else if isConnected(presentation), identityIsResolved {
            previewStates[key]?.verifyIdentity(presentation.identity())
        }
        if identityIsResolved {
            reconnectingKeys.remove(key)
        }
        publish(key)
        reconcileEligibility()
        requestIdentityIfNeeded(key)
        captureExpandedEfficientActiveIfNeeded(key)
    }

    func presentationDidChange(_ key: TmuxPreviewKey) {
        guard let presentation = presentations[key] else { return }
        parkingBlockedKeys.remove(key)
        invalidate(key)
        switch presentation.connectionState() {
        case .connected where !unresolvedIdentityKeys.contains(key):
            previewStates[key]?.verifyIdentity(presentation.identity())
        case .disconnected:
            unparkAndRelease(key)
            previewStates[key]?.setDisconnected()
        case .connecting, .reconnecting, .connected, nil:
            unparkAndRelease(key)
            previewStates[key]?.beginReconnect()
        }
        publish(key)
        reconcileEligibility()
        requestIdentityIfNeeded(key)
        captureExpandedEfficientActiveIfNeeded(key)
    }

    func setExpanded(_ expanded: Bool, for key: TmuxPreviewKey) {
        guard presentations[key] != nil else { return }
        let changed = expanded
            ? expandedKeys.insert(key).inserted
            : expandedKeys.remove(key) != nil
        guard changed else { return }
        parkingBlockedKeys.remove(key)
        invalidate(key)
        invalidateActivationDelay()
        if !expanded {
            unparkAndRelease(key)
        }
        publish(key)
        reconcileEligibility()
        requestIdentityIfNeeded(key)
        if expanded, mode == .efficient,
           presentations[key]?.isActive() == true {
            startCapture(key, reason: .scheduled)
        }
    }

    func setMode(_ newMode: SessionPreviewMode) {
        guard mode != newMode else { return }
        let keys = Array(presentations.keys)
        let formerlyParked = parkedKeys
        mode = newMode
        invalidateActivationDelay()
        keys.forEach(invalidate)
        liveTask?.cancel()
        liveTask = nil

        switch newMode {
        case .off:
            for key in keys {
                unparkAndRelease(key)
                previewStates[key]?.setMode(.off)
                publish(key)
            }
        case .efficient:
            for key in formerlyParked {
                startCapture(
                    key,
                    reason: .finalBeforeUnpark,
                    completion: { [weak self] in
                        guard self?.mode == .efficient else { return }
                        self?.unparkAndRelease(key)
                    }
                )
            }
            keys.filter { !formerlyParked.contains($0) }
                .forEach(unparkAndRelease)
        case .live:
            reconcileEligibility()
        }
        keys.forEach(publish)
        keys.forEach(requestIdentityIfNeeded)
        restartLiveTaskIfNeeded()
    }

    func setSidebarVisible(_ visible: Bool) {
        guard isSidebarVisible != visible else { return }
        isSidebarVisible = visible
        invalidateAllEligibility()
        if !visible {
            releaseAllParking()
        } else {
            reconcileEligibility()
        }
        restartLiveTaskIfNeeded()
    }

    func applicationDidResignActive() {
        guard isApplicationActive else { return }
        isApplicationActive = false
        invalidateAllEligibility()
        releaseAllParking()
        liveTask?.cancel()
        liveTask = nil
    }

    func applicationDidBecomeActive() {
        guard !isApplicationActive else { return }
        isApplicationActive = true
        guard sceneIsKeyWindow() else { return }
        scheduleParkingReacquisition()
    }

    func sceneWindowFocusDidChange(isKey: Bool) {
        guard isApplicationActive else { return }
        guard isKey else {
            invalidateActivationDelay()
            return
        }
        scheduleParkingReacquisition()
    }

    func cancelPendingActivation() {
        guard !isInvokingActivation else { return }
        navigationGeneration &+= 1
        let keys = activatingKeys
        for key in keys {
            invalidate(key)
            publish(key)
        }
        reconcileEligibility()
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        invalidateActivationDelay()
        navigationGeneration &+= 1
        liveTask?.cancel()
        liveTask = nil
        pendingTasks.values.forEach { $0.cancel() }
        pendingTasks.removeAll()
        activeCaptureIDs.removeAll()
        isParkingHostChanging = true
        releaseAllParking()
        isParkingHostChanging = false
        budget.release(sceneID: sceneID)
        budgetCancellable?.cancel()
        budgetCancellable = nil
        presentations.removeAll()
        registeredVersions.removeAll()
        previewStates.removeAll()
        viewStates.removeAll()
        expandedKeys.removeAll()
        parkedKeys.removeAll()
        activatingKeys.removeAll()
        reconnectingKeys.removeAll()
        unresolvedIdentityKeys.removeAll()
        parkingBlockedKeys.removeAll()
        generations.removeAll()
    }

    private func scheduleParkingReacquisition() {
        guard mode == .live,
              isApplicationActive,
              isSidebarVisible,
              activationTask == nil
        else { return }
        invalidateActivationDelay()
        let generation = activationGeneration
        activationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sleep(activationDelay)
            } catch {
                return
            }
            guard generation == activationGeneration else { return }
            activationTask = nil
            guard isApplicationActive,
                  isSidebarVisible,
                  mode == .live,
                  sceneIsKeyWindow()
            else { return }
            reconcileEligibility()
            restartLiveTaskIfNeeded()
        }
    }

    func captureActiveIfNeeded(_ key: TmuxPreviewKey) {
        guard presentations[key]?.isActive() == true else { return }
        startCapture(key, reason: .scheduled)
    }

    func captureBeforeDeactivation(
        _ key: TmuxPreviewKey,
        completion: (() -> Void)? = nil
    ) {
        guard presentations[key]?.isActive() == true else {
            completion?()
            return
        }
        startCapture(key, reason: .navigationAway, completion: completion)
    }

    func prepareToActivate(
        _ key: TmuxPreviewKey,
        activate: (() -> Void)? = nil
    ) {
        guard let presentation = presentations[key] else { return }
        guard mode != .off else {
            (activate ?? presentation.activate)()
            return
        }
        cancelPendingActivation()
        invalidate(key)
        invalidateActivationDelay()
        activatingKeys.insert(key)
        unparkAndRelease(key)
        isInvokingActivation = true
        (activate ?? presentation.activate)()
        isInvokingActivation = false
        guard presentations[key] != nil else { return }
        activatingKeys.remove(key)
        publish(key)
        reconcileEligibility()
    }

    func remove(_ key: TmuxPreviewKey, reason: RemovalReason) {
        guard presentations[key] != nil else { return }
        invalidate(key)
        invalidateActivationDelay()
        reconnectingKeys.insert(key)
        unparkAndRelease(key)
        switch reason {
        case .reconnect:
            unresolvedIdentityKeys.insert(key)
            if case .disconnected = presentations[key]?.connectionState() {
                previewStates[key]?.setDisconnected()
            } else {
                previewStates[key]?.beginReconnect()
            }
            publish(key)
        case .close:
            expandedKeys.remove(key)
            activatingKeys.remove(key)
            reconnectingKeys.remove(key)
            presentations.removeValue(forKey: key)
            registeredVersions.removeValue(forKey: key)
            previewStates.removeValue(forKey: key)
            viewStates.removeValue(forKey: key)
            generations.removeValue(forKey: key)
            unresolvedIdentityKeys.remove(key)
            parkingBlockedKeys.remove(key)
        case .replacement:
            activatingKeys.remove(key)
            reconnectingKeys.remove(key)
            presentations.removeValue(forKey: key)
            registeredVersions.removeValue(forKey: key)
            previewStates.removeValue(forKey: key)
            viewStates.removeValue(forKey: key)
            generations.removeValue(forKey: key)
            unresolvedIdentityKeys.remove(key)
            parkingBlockedKeys.remove(key)
        }
        restartLiveTaskIfNeeded()
    }

    func installParkingHost(_ host: LivePreviewParkingHost) {
        guard parkingHost !== host else { return }
        if parkingHost != nil {
            isParkingHostChanging = true
            releaseAllParking()
            isParkingHostChanging = false
        }
        parkingHost = host
        reconcileEligibility()
    }

    func removeParkingHost(_ host: LivePreviewParkingHost) {
        guard parkingHost === host else { return }
        isParkingHostChanging = true
        releaseAllParking()
        parkingHost = nil
        isParkingHostChanging = false
    }

    func refreshLivePreviews() async {
        guard mode == .live,
              isApplicationActive,
              isSidebarVisible,
              !isParkingHostChanging
        else { return }
        presentations.keys.forEach(requestIdentityIfNeeded)
        reconcileEligibility()
        for key in expandedKeys {
            guard let presentation = presentations[key],
                  isConnected(presentation),
                  presentation.identity() != nil
            else { continue }
            if presentation.isActive()
                || (parkedKeys.contains(key) && isGranted(key)) {
                startCapture(key, reason: .scheduled)
            }
        }
    }

    func waitForPendingWork() async {
        while !pendingTasks.isEmpty {
            let tasks = pendingTasks.values
            for task in tasks {
                await task.value
            }
            await Task.yield()
        }
    }

    private func startCapture(
        _ key: TmuxPreviewKey,
        reason: CaptureReason,
        completion: (() -> Void)? = nil
    ) {
        if activeCaptureIDs[key] != nil {
            switch reason {
            case .scheduled:
                completion?()
                return
            case .navigationAway, .finalBeforeUnpark:
                cancelCapture(for: key)
            }
        }
        guard let presentation = presentations[key],
              captureCanStart(key, presentation: presentation, reason: reason),
              let identity = presentation.identity()
        else {
            if let completion, presentations[key] != nil {
                completion()
            }
            return
        }
        let captureGeneration = generations[key, default: 0]
        let presentationVersion = version(of: presentation)
        let previousToken = previewStates[key]?.visibleFrame?.captureToken
        let operationID = UUID()
        activeCaptureIDs[key] = operationID
        let captureOperation = switch reason {
        case .scheduled: capture
        case .navigationAway, .finalBeforeUnpark: finalCapture
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let snapshot = try await captureOperation(
                    presentation,
                    previousToken
                ),
                    await presentation.refreshIdentity() == identity,
                    captureCanPublish(
                        key,
                        presentationVersion: presentationVersion,
                        identity: identity,
                        generation: captureGeneration,
                        reason: reason
                    ) {
                    previewStates[key]?.recordCapture(
                        image: snapshot.image,
                        capturedAt: now(),
                        captureToken: snapshot.captureToken,
                        identity: identity
                    )
                    publish(key)
                }
            } catch {
                if generations[key, default: 0] == captureGeneration {
                    previewStates[key]?.recordCaptureFailure()
                    publish(key)
                }
            }
            if generations[key, default: 0] == captureGeneration {
                completion?()
            }
            finishTask(operationID, for: key)
        }
        pendingTasks[operationID] = task
    }

    private func finishTask(_ operationID: UUID, for key: TmuxPreviewKey) {
        pendingTasks.removeValue(forKey: operationID)
        if activeCaptureIDs[key] == operationID {
            activeCaptureIDs.removeValue(forKey: key)
        }
    }

    private func cancelCapture(for key: TmuxPreviewKey) {
        generations[key, default: 0] &+= 1
        guard let operationID = activeCaptureIDs.removeValue(forKey: key)
        else { return }
        pendingTasks[operationID]?.cancel()
    }

    private func captureCanStart(
        _ key: TmuxPreviewKey,
        presentation: Presentation,
        reason: CaptureReason
    ) -> Bool {
        guard mode != .off,
              isConnected(presentation),
              presentation.identity() != nil
        else { return false }
        switch reason {
        case .scheduled:
            guard isApplicationActive,
                  isSidebarVisible,
                  expandedKeys.contains(key)
            else { return false }
            if presentation.isActive() {
                return mode == .efficient || mode == .live
            }
            return mode == .live
                && parkedKeys.contains(key)
                && isGranted(key)
        case .navigationAway:
            guard isApplicationActive else { return false }
            return mode == .efficient || expandedKeys.contains(key)
        case .finalBeforeUnpark:
            return mode == .efficient && parkedKeys.contains(key)
        }
    }

    private func captureCanPublish(
        _ key: TmuxPreviewKey,
        presentationVersion: PresentationVersion,
        identity: TmuxSessionIdentity,
        generation: UInt64,
        reason: CaptureReason
    ) -> Bool {
        guard generations[key, default: 0] == generation,
              let presentation = presentations[key],
              version(of: presentation) == presentationVersion,
              presentation.identity() == identity,
              isConnected(presentation),
              captureCanStart(key, presentation: presentation, reason: reason)
        else { return false }
        return true
    }

    private func reconcileEligibility() {
        guard !isShutDown,
              mode == .live,
              isApplicationActive,
              isSidebarVisible,
              !isParkingHostChanging
        else {
            restartLiveTaskIfNeeded()
            return
        }

        for key in presentations.keys {
            guard let presentation = presentations[key] else { continue }
            let eligible = expandedKeys.contains(key)
                && isConnected(presentation)
                && presentation.identity() != nil
                && !reconnectingKeys.contains(key)
                && !parkingBlockedKeys.contains(key)
            if activatingKeys.contains(key) {
                continue
            }
            if !eligible || presentation.isActive() {
                unparkAndRelease(key)
            } else {
                budget.request(requestID(for: key))
            }
        }

        for key in presentations.keys {
            guard let presentation = presentations[key],
                  expandedKeys.contains(key),
                  !presentation.isActive(),
                  !activatingKeys.contains(key),
                  !reconnectingKeys.contains(key),
                  isConnected(presentation),
                  presentation.identity() != nil
            else { continue }
            if isGranted(key) {
                do {
                    try park(key, presentation: presentation)
                } catch {
                    parkingBlockedKeys.insert(key)
                    budget.release(requestID(for: key))
                }
            }
            previewStates[key]?.setLiveLimitReached(
                budget.isWaiting(requestID(for: key))
            )
            publish(key)
        }
        restartLiveTaskIfNeeded()
    }

    private func park(
        _ key: TmuxPreviewKey,
        presentation: Presentation
    ) throws {
        guard !parkedKeys.contains(key) else { return }
        if let injectedPark {
            try injectedPark(presentation)
        } else {
            guard let host = parkingHost,
                  let surface = presentation.surface()
            else { return }
            try host.park(surface)
        }
        parkedKeys.insert(key)
        publish(key)
    }

    private func unparkAndRelease(_ key: TmuxPreviewKey) {
        if parkedKeys.remove(key) != nil,
           let presentation = presentations[key] {
            if let injectedUnpark {
                injectedUnpark(presentation)
            } else if let surface = presentation.surface() {
                parkingHost?.unpark(surface)
            }
        }
        budget.release(requestID(for: key))
        previewStates[key]?.setLiveLimitReached(false)
        publish(key)
    }

    private func releaseAllParking() {
        Array(parkedKeys).forEach(unparkAndRelease)
        budget.release(sceneID: sceneID)
    }

    private func restartLiveTaskIfNeeded() {
        let shouldRun = !isShutDown
            && mode == .live
            && isApplicationActive
            && isSidebarVisible
            && !expandedKeys.isEmpty
        guard shouldRun else {
            liveTask?.cancel()
            liveTask = nil
            return
        }
        guard liveTask == nil else { return }
        liveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.liveInterval,
                      let sleep = self?.sleep
                else { return }
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard let self else { return }
                await refreshLivePreviews()
            }
        }
    }

    private func budgetGrantsChanged(
        _ granted: Set<LivePreviewRequestID>
    ) {
        guard !isShutDown else { return }
        let lost = lastGranted.subtracting(granted)
            .filter { $0.sceneID == sceneID }
        lastGranted = granted
        for request in lost {
            if activatingKeys.contains(request.presentation) {
                continue
            }
            invalidate(request.presentation)
            if parkedKeys.contains(request.presentation) {
                unparkAndRelease(request.presentation)
            }
        }
        reconcileEligibility()
    }

    private func invalidate(_ key: TmuxPreviewKey) {
        generations[key, default: 0] &+= 1
        activatingKeys.remove(key)
        if let operationID = activeCaptureIDs.removeValue(forKey: key) {
            pendingTasks[operationID]?.cancel()
        }
    }

    private func invalidateAllEligibility() {
        presentations.keys.forEach(invalidate)
        invalidateActivationDelay()
    }

    private func invalidateActivationDelay() {
        activationGeneration &+= 1
        activationTask?.cancel()
        activationTask = nil
    }

    private func requestID(for key: TmuxPreviewKey) -> LivePreviewRequestID {
        LivePreviewRequestID(sceneID: sceneID, presentation: key)
    }

    private func isGranted(_ key: TmuxPreviewKey) -> Bool {
        budget.isGranted(requestID(for: key))
    }

    private func isConnected(_ presentation: Presentation) -> Bool {
        presentation.connectionState() == .connected
    }

    private func captureExpandedEfficientActiveIfNeeded(
        _ key: TmuxPreviewKey
    ) {
        guard mode == .efficient,
              expandedKeys.contains(key),
              presentations[key]?.isActive() == true
        else { return }
        startCapture(key, reason: .scheduled)
    }

    private func requestIdentityIfNeeded(_ key: TmuxPreviewKey) {
        guard requiresIdentity(key), let presentation = presentations[key]
        else { return }
        presentation.ensureIdentity()
    }

    func requiresIdentity(_ key: TmuxPreviewKey) -> Bool {
        mode != .off
            && unresolvedIdentityKeys.contains(key)
            && presentations[key].map(isConnected) == true
            && (
                expandedKeys.contains(key)
                    || (
                        mode == .efficient
                            && presentations[key]?.isActive() == true
                    )
            )
    }

    private func sceneIsKeyWindow() -> Bool {
        if let injectedIsKeyWindow {
            return injectedIsKeyWindow()
        }
        return parkingHost?.window?.isKeyWindow == true
    }

    private func version(of presentation: Presentation) -> PresentationVersion {
        PresentationVersion(
            handleID: presentation.handleID(),
            generation: presentation.generation()
        )
    }

    private func publish(_ key: TmuxPreviewKey) {
        guard let state = previewStates[key] else { return }
        let presentation = presentations[key]
        viewStates[key] = TmuxPreviewViewState(
            image: state.visibleFrame?.image,
            capturedAt: state.visibleFrame?.capturedAt,
            placeholder: state.placeholder,
            connectionState: presentation?.connectionState(),
            isLive: mode == .live
                && isApplicationActive
                && isSidebarVisible
                && presentation.map(isConnected) == true
                && !reconnectingKeys.contains(key)
                && !unresolvedIdentityKeys.contains(key)
                && (presentation?.isActive() == true || parkedKeys.contains(key))
        )
    }
}
