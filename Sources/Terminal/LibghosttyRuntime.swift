import AppKit
import Combine
import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace
import GhosttyKit
import os.log
import UniformTypeIdentifiers

private struct ResolvedColorCallbackGeneration: Equatable {
    let configuration: UInt64
    let surface: UInt64
}

private final class ResolvedColorGenerationTracker: @unchecked Sendable {
    private struct SurfaceGeneration {
        var value: UInt64
        var isAlive: Bool
    }

    private let lock = NSLock()
    private var configuration: UInt64 = 0
    private var surfaces: [UInt: SurfaceGeneration] = [:]

    func registerSurface(_ identity: UInt) {
        lock.lock()
        defer { lock.unlock() }
        let previous = surfaces[identity]
        surfaces[identity] = SurfaceGeneration(
            value: (previous?.value ?? 0) + 1,
            isAlive: true
        )
    }

    func unregisterSurface(_ identity: UInt) {
        lock.lock()
        defer { lock.unlock() }
        guard var generation = surfaces[identity], generation.isAlive else {
            return
        }
        generation.value += 1
        generation.isAlive = false
        surfaces[identity] = generation
    }

    func advanceConfiguration() {
        lock.lock()
        configuration += 1
        lock.unlock()
    }

    func advanceSurface(_ identity: UInt) {
        lock.lock()
        defer { lock.unlock() }
        guard var generation = surfaces[identity], generation.isAlive else {
            return
        }
        generation.value += 1
        surfaces[identity] = generation
    }

    func snapshot(
        forSurface identity: UInt
    ) -> ResolvedColorCallbackGeneration? {
        lock.lock()
        defer { lock.unlock() }
        guard let generation = surfaces[identity], generation.isAlive else {
            return nil
        }
        return ResolvedColorCallbackGeneration(
            configuration: configuration,
            surface: generation.value
        )
    }

    func isCurrent(
        _ candidate: ResolvedColorCallbackGeneration,
        forSurface identity: UInt
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let generation = surfaces[identity], generation.isAlive else {
            return false
        }
        return candidate.configuration == configuration
            && candidate.surface == generation.value
    }
}

@MainActor
public protocol ApplicationQuitRequestSource: AnyObject {
    var quitRequestHandler: (() -> Void)? { get set }
}

@MainActor
public final class LibghosttyRuntime: ObservableObject,
    ApplicationQuitRequestSource {
    private struct ResolvedColorEntry {
        let colors: TerminalResolvedColors
        let generation: ResolvedColorCallbackGeneration
    }

    struct ConfigMonitorRequest {
        let files: [URL]
        let errorHandler: LibghosttyConfigFileMonitor.ErrorHandler
        let changeHandler: LibghosttyConfigFileMonitor.ChangeHandler
    }

    typealias ConfigMonitorFactory = (
        ConfigMonitorRequest
    ) -> LibghosttyConfigFileMonitor

    struct ClipboardWriteEntry: Equatable {
        let mime: String
        let data: String
    }

    enum OSC52ClipboardWriteDiagnostic: Equatable {
        case confirmationRequired
        case surfaceUnavailable
        case noWritableContent
        case pasteboardRejected(entryCount: Int, byteCount: Int)
        case written(entryCount: Int, byteCount: Int)
    }

    nonisolated static let osc52ClipboardWriteMIME =
        "application/x-ghosthub-osc52"
    private static let osc52ClipboardLog = OSLog(
        subsystem: "com.ghosthub.app",
        category: "clipboard"
    )
    static var osc52ClipboardWriteDiagnosticObserver:
        ((OSC52ClipboardWriteDiagnostic) -> Void)?
    static var urlOpener: (URL) -> Bool = { url in
        NSWorkspace.shared.open(url)
    }

    public static let shared = LibghosttyRuntime(
        pipeline: LibghosttyConfigPipeline(
            paths: LibghosttyConfigPaths(
                configDirectory: ConfigHome.resolved()
            )
        )
    )

    @Published public private(set) var bootstrapStatus: LibghosttyBootstrapStatus
    @Published public private(set) var phase: LibghosttyRuntimePhase
    @Published public private(set) var configPlan: LibghosttyConfigLoadPlan?
    @Published public private(set) var diagnostics: [String]
    @Published public private(set) var configReloadNotice:
        LibghosttyConfigReloadNotice?
    @Published public private(set) var resolvedTerminalColorsBySurface:
        [UInt: TerminalResolvedColors]
    @Published public private(set) var backgroundAppearance:
        TerminalBackgroundAppearance = .opaque

    public let runtimeState: LibghosttyRuntimeState
    public let renderTracker = SurfaceRenderTracker()
    public var quitRequestHandler: (() -> Void)?

    private let configReloadNoticeSubject =
        PassthroughSubject<LibghosttyConfigReloadNotice?, Never>()
    private let pipeline: LibghosttyConfigPipeline
    private let configMonitorFactory: ConfigMonitorFactory
    private let increasedContrastProvider: () -> Bool
    private nonisolated let resolvedColorGenerations =
        ResolvedColorGenerationTracker()
    private var resolvedColorEntries: [UInt: ResolvedColorEntry] = [:]
    private var liveResolvedColorSurfaceIdentities: Set<UInt> = []
    private nonisolated(unsafe) var appHandle: ghostty_app_t?
    private nonisolated(unsafe) var configHandle: ghostty_config_t?
    private var activeConfigRoot: URL?
    private var configMonitor: LibghosttyConfigFileMonitor?
    private var monitorFailureMessage: String?
    private var monitorFailureNoticeID: UUID?
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private nonisolated(unsafe) var workspaceNotificationObservers:
        [NSObjectProtocol] = []
    private static var didInitializeLibrary = false

    public var configPaths: LibghosttyConfigPaths {
        pipeline.paths
    }

    public var configReloadNotices:
        AnyPublisher<LibghosttyConfigReloadNotice?, Never> {
        configReloadNoticeSubject.eraseToAnyPublisher()
    }

    public var needsConfirmQuit: Bool {
        guard let appHandle else { return false }
        return ghostty_app_needs_confirm_quit(appHandle)
    }

    /// Applies the configured background blur to a window via libghostty.
    /// Safe to call repeatedly; radius 0 clears any existing blur. No effect
    /// unless the window is visible, so callers re-apply on focus changes.
    public func applyWindowBackgroundBlur(to window: NSWindow) {
        guard let appHandle else { return }
        ghostty_set_window_background_blur(
            appHandle,
            Unmanaged.passUnretained(window).toOpaque()
        )
    }

    /// Colors shared by every live surface in the current configuration.
    /// A disagreement is unavailable rather than selecting an arbitrary
    /// surface for attachment-time tmux styling.
    public var resolvedTerminalColors: TerminalResolvedColors? {
        guard Set(resolvedTerminalColorsBySurface.keys)
            == liveResolvedColorSurfaceIdentities else { return nil }
        guard let first = resolvedTerminalColorsBySurface.values.first,
              resolvedTerminalColorsBySurface.values.allSatisfy({ $0 == first })
        else { return nil }
        return first
    }

    public func resolvedTerminalColors(
        forSurfaceIdentity identity: UInt
    ) -> TerminalResolvedColors? {
        resolvedTerminalColorsBySurface[identity]
    }

    func requestQuit() {
        runtimeState.recordAction(.quit)
        quitRequestHandler?()
    }

    var unsafeAppHandle: ghostty_app_t? {
        appHandle
    }

    var unsafeConfigHandle: ghostty_config_t? {
        configHandle
    }

    public convenience init(
        pipeline: LibghosttyConfigPipeline = .live,
        runtimeState: LibghosttyRuntimeState? = nil
    ) {
        self.init(
            pipeline: pipeline,
            runtimeState: runtimeState,
            configMonitorFactory: { request in
                LibghosttyConfigFileMonitor(
                    fileURLs: request.files,
                    errorHandler: request.errorHandler,
                    changeHandler: request.changeHandler
                )
            }
        )
    }

    init(
        pipeline: LibghosttyConfigPipeline,
        runtimeState: LibghosttyRuntimeState? = nil,
        configMonitorFactory: @escaping ConfigMonitorFactory,
        increasedContrastProvider: @escaping () -> Bool = {
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        }
    ) {
        self.pipeline = pipeline
        self.configMonitorFactory = configMonitorFactory
        self.increasedContrastProvider = increasedContrastProvider
        self.runtimeState = runtimeState ?? LibghosttyRuntimeState()
        bootstrapStatus = .ready()
        phase = .loadingConfig
        diagnostics = []
        configReloadNotice = nil
        resolvedTerminalColorsBySurface = [:]

        initializeLibghostty()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }

        for observer in workspaceNotificationObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }

        if let appHandle {
            ghostty_app_free(appHandle)
        }

        if let configHandle {
            ghostty_config_free(configHandle)
        }
    }

    public func preconditionReady(file: StaticString = #file, line: UInt = #line) {
        guard bootstrapStatus.isReady, phase == .ready else {
            let message = bootstrapStatus.message ?? "libghostty failed to initialize."
            preconditionFailure(message, file: file, line: line)
        }
    }

    @discardableResult
    public func reloadConfig(
        projectRoot: URL? = nil,
        force: Bool = false,
        notifyOnSuccess: Bool = false
    ) -> LibghosttyConfigReloadResult {
        reloadConfig(
            target: nil,
            projectRoot: projectRoot,
            force: force,
            notifyOnSuccess: notifyOnSuccess
        )
    }

    @discardableResult
    public func reloadActiveConfig(
        force: Bool = true,
        notifyOnSuccess: Bool = true
    ) -> LibghosttyConfigReloadResult {
        reloadConfig(
            target: nil,
            projectRoot: activeConfigRoot,
            force: force,
            notifyOnSuccess: notifyOnSuccess
        )
    }

    @discardableResult
    public func reloadConfig(
        target: ghostty_target_s?,
        projectRoot: URL? = nil,
        force: Bool = false,
        notifyOnSuccess: Bool = false
    ) -> LibghosttyConfigReloadResult {
        guard let appHandle else {
            return .failed("libghostty is not initialized.")
        }
        guard force || activeConfigRoot != projectRoot else {
            return .unchanged
        }
        activeConfigRoot = projectRoot

        do {
            let prepared = try prepareConfigLoad(
                projectRoot: projectRoot
            )
            let plan = prepared.plan
            let monitorFailure = prepared.monitorFailure
            let config = try loadConfig(plan: plan)
            let candidateDiagnostics = readDiagnostics(from: config)

            guard candidateDiagnostics.isEmpty else {
                ghostty_config_free(config)
                diagnostics = candidateDiagnostics
                if let monitorFailure {
                    recordMonitorFailure(
                        monitorFailure,
                        publishNotice: false
                    )
                } else {
                    clearMonitorFailure()
                }
                phase = .ready
                publishReloadFailure(diagnostics)
                return .rejected(diagnostics)
            }

            if let target,
               target.tag == GHOSTTY_TARGET_SURFACE,
               let surfaceHandle = target.target.surface {
                invalidateResolvedColors(
                    forSurfaceIdentity: UInt(bitPattern: surfaceHandle)
                )
                ghostty_surface_update_config(surfaceHandle, config)
                ghostty_config_free(config)
            } else {
                resolvedColorGenerations.advanceConfiguration()
                resolvedColorEntries.removeAll()
                publishResolvedColors()
                ghostty_app_update_config(appHandle, config)
                replaceConfigHandle(with: config)
            }
            configPlan = plan
            phase = .ready
            if let monitorFailure {
                diagnostics = []
                recordMonitorFailure(monitorFailure)
                return .appliedWithWarnings(diagnostics)
            }
            clearMonitorFailure()
            diagnostics = []
            if notifyOnSuccess {
                setConfigReloadNotice(
                    LibghosttyConfigReloadNotice(
                        kind: .success,
                        message: "Terminal configuration reloaded."
                    )
                )
            } else if configReloadNotice?.kind == .error {
                setConfigReloadNotice(nil)
            }
            return .applied
        } catch {
            phase = .ready
            diagnostics = [error.localizedDescription]
            publishReloadFailure(diagnostics)
            return .failed(error.localizedDescription)
        }
    }

    func registerSurfaceForResolvedColors(_ surface: ghostty_surface_t) {
        let identity = UInt(bitPattern: surface)
        resolvedColorGenerations.registerSurface(identity)
        liveResolvedColorSurfaceIdentities.insert(identity)
        resolvedColorEntries.removeValue(forKey: identity)
        // Surfaces are created lazily during SwiftUI body evaluation, so the
        // @Published mutation must wait until the view update finishes.
        // publishResolvedColors re-reads current state, so a deferred publish
        // is never stale.
        DispatchQueue.main.async { [weak self] in
            self?.publishResolvedColors(force: true)
        }
        // Surface creation can publish its initial config before the
        // coordinator knows its identity. Republish after registration so
        // same-scheme surfaces also populate the current generation.
        if let configHandle {
            ghostty_surface_update_config(surface, configHandle)
        }
    }

    func unregisterSurfaceForResolvedColors(_ identity: UInt) {
        resolvedColorGenerations.unregisterSurface(identity)
        liveResolvedColorSurfaceIdentities.remove(identity)
        resolvedColorEntries.removeValue(forKey: identity)
        publishResolvedColors(force: true)
    }

    private func invalidateResolvedColors(forSurfaceIdentity identity: UInt) {
        resolvedColorGenerations.advanceSurface(identity)
        resolvedColorEntries.removeValue(forKey: identity)
        publishResolvedColors()
    }

    private func recordResolvedColors(
        _ colors: TerminalResolvedColors,
        forSurfaceIdentity identity: UInt,
        generation: ResolvedColorCallbackGeneration
    ) {
        guard resolvedColorGenerations.isCurrent(
            generation,
            forSurface: identity
        ) else { return }
        let previous = resolvedColorEntries[identity]
        guard previous?.colors != colors
            || previous?.generation != generation else { return }
        resolvedColorEntries[identity] = ResolvedColorEntry(
            colors: colors,
            generation: generation
        )
        publishResolvedColors()
    }

    private func publishResolvedColors(force: Bool = false) {
        let colors = resolvedColorEntries.mapValues(\.colors)
        if force || resolvedTerminalColorsBySurface != colors {
            resolvedTerminalColorsBySurface = colors
        }
    }

    private func prepareConfigLoad(
        projectRoot: URL?
    ) throws -> (
        plan: LibghosttyConfigLoadPlan,
        monitorFailure: String?
    ) {
        var plan = try pipeline.loadPlan(projectRoot: projectRoot)
        var remainingAttempts = 4

        while true {
            let monitorFailure: String?
            do {
                try updateConfigMonitor(for: plan)
                monitorFailure = nil
            } catch {
                monitorFailure = error.localizedDescription
            }

            let refreshedPlan = try pipeline.loadPlan(
                projectRoot: projectRoot
            )
            let graphIsStable =
                plan.orderedConfigFiles
                    == refreshedPlan.orderedConfigFiles
                    && plan.watchedConfigFiles
                    == refreshedPlan.watchedConfigFiles
            if graphIsStable {
                return (refreshedPlan, monitorFailure)
            }
            guard remainingAttempts > 0 else {
                throw LibghosttyInitializationError
                    .unstableConfigGraph
            }
            remainingAttempts -= 1
            plan = refreshedPlan
        }
    }

    private func initializeLibghostty() {
        guard Self.ensureLibraryInitialized() else {
            bootstrapStatus = .missing(
                message: "libghostty failed to initialize. Re-run `make bootstrap-libghostty` and relaunch Ghosthub."
            )
            phase = .failed("ghostty_init failed")
            diagnostics = ["ghostty_init failed"]
            return
        }

        do {
            let prepared = try prepareConfigLoad(projectRoot: nil)
            let plan = prepared.plan
            let config = try loadConfig(plan: plan)
            var runtimeConfig = ghostty_runtime_config_s()
            runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
            runtimeConfig.supports_selection_clipboard = true
            runtimeConfig.wakeup_cb = ghosttyRuntimeWakeupCallback
            runtimeConfig.action_cb = ghosttyRuntimeActionCallback
            runtimeConfig.read_clipboard_cb = ghosttyRuntimeReadClipboardCallback
            runtimeConfig.confirm_read_clipboard_cb =
                ghosttyRuntimeConfirmReadClipboardCallback
            runtimeConfig.write_clipboard_cb =
                ghosttyRuntimeWriteClipboardCallback
            runtimeConfig.close_surface_cb = ghosttyRuntimeCloseSurfaceCallback
            runtimeConfig.child_write_cb = ghosttyRuntimeChildWriteCallback

            guard let appHandle = ghostty_app_new(&runtimeConfig, config) else {
                throw LibghosttyInitializationError.createApp
            }

            self.appHandle = appHandle
            ghostty_app_keyboard_changed(appHandle)
            ghostty_app_set_focus(appHandle, NSApplication.shared.isActive)
            replaceConfigHandle(with: config)
            configPlan = plan
            diagnostics = readDiagnostics(from: config)
            installApplicationObservers()
            if let monitorFailure = prepared.monitorFailure {
                recordMonitorFailure(monitorFailure)
            } else {
                clearMonitorFailure()
            }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            diagnostics = [error.localizedDescription]
        }
    }

    private func loadConfig(plan: LibghosttyConfigLoadPlan) throws -> ghostty_config_t {
        guard let config = ghostty_config_new() else {
            throw LibghosttyInitializationError.createConfig
        }

        try loadConfigFiles(plan: plan, into: config)
        ghostty_config_finalize(config)
        return config
    }

    private func loadConfigFiles(
        plan: LibghosttyConfigLoadPlan,
        into config: ghostty_config_t
    ) throws {
        let shimDir = pipeline.paths.configDirectory
            .appendingPathComponent(".ghostty-shim", isDirectory: true)
        let shimConfigFile = shimDir
            .appendingPathComponent("config", isDirectory: false)

        try FileManager.default.createDirectory(
            at: shimDir,
            withIntermediateDirectories: true
        )

        // Load only Ghosthub-owned terminal config. The shim file
        // contains config-file directives pointing at the real files,
        // and the bootstrap patch exports ghostty_config_load_file so
        // we do not need libghostty's default file discovery at all.
        var shimContent = ""
        for url in plan.orderedConfigFiles {
            shimContent += "config-file = \(url.path)\n"
        }

        try shimContent.write(
            to: shimConfigFile, atomically: true, encoding: .utf8
        )

        let shimPath = shimConfigFile.path
        shimPath.withCString { pointer in
            ghostty_config_load_file(config, pointer, shimPath.utf8.count)
        }
        ghostty_config_load_recursive_files(config)
    }

    private func replaceConfigHandle(with config: ghostty_config_t) {
        if let existing = configHandle {
            ghostty_config_free(existing)
        }
        configHandle = config
        refreshBackgroundAppearance()
    }

    private func refreshBackgroundAppearance() {
        guard let configHandle else { return }
        let appearance = Self.readBackgroundAppearance(
            from: configHandle,
            increasedContrast: increasedContrastProvider()
        )
        if appearance != backgroundAppearance {
            backgroundAppearance = appearance
        }
    }

    private func readDiagnostics(from config: ghostty_config_t) -> [String] {
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else {
            return []
        }

        return (0 ..< count).map { index in
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            return String(cString: diagnostic.message)
        }
    }

    private func installApplicationObservers() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let appHandle = self?.appHandle else { return }
                ghostty_app_keyboard_changed(appHandle)
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let appHandle = self?.appHandle else { return }
                ghostty_app_set_focus(appHandle, true)
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let appHandle = self?.appHandle else { return }
                ghostty_app_set_focus(appHandle, false)
            }
        )
        // Accessibility display notifications post on NSWorkspace's own
        // notification center, not NotificationCenter.default.
        workspaceNotificationObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace
                    .accessibilityDisplayOptionsDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshBackgroundAppearance()
                }
            }
        )
    }

    private func updateConfigMonitor(
        for plan: LibghosttyConfigLoadPlan
    ) throws {
        if let configMonitor {
            try configMonitor.update(
                fileURLs: plan.watchedConfigFiles
            )
            return
        }

        let monitor = makeConfigMonitor(for: plan)
        do {
            try monitor.start()
            configMonitor = monitor
        } catch {
            configMonitor = monitor
            throw error
        }
    }

    private func makeConfigMonitor(
        for plan: LibghosttyConfigLoadPlan
    ) -> LibghosttyConfigFileMonitor {
        configMonitorFactory(
            ConfigMonitorRequest(
                files: plan.watchedConfigFiles,
                errorHandler: { [weak self] error in
                    Task { @MainActor in
                        self?.recordMonitorFailure(
                            error.localizedDescription
                        )
                    }
                },
                changeHandler: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        self.reloadActiveConfig(
                            force: true,
                            notifyOnSuccess: false
                        )
                    }
                }
            )
        )
    }

    private func publishReloadFailure(_ messages: [String]) {
        let first = messages.first
            ?? "The configuration could not be loaded."
        let suffix = messages.count > 1
            ? " (+\(messages.count - 1) more)"
            : ""
        setConfigReloadNotice(
            LibghosttyConfigReloadNotice(
                kind: .error,
                message: "Configuration not reloaded: \(first)\(suffix)"
            )
        )
    }

    private func recordMonitorFailure(
        _ message: String,
        publishNotice: Bool = true
    ) {
        let isDuplicate = monitorFailureMessage == message
            && configReloadNotice?.id == monitorFailureNoticeID
        if let previous = monitorFailureMessage,
           previous != message {
            diagnostics.removeAll { $0 == previous }
        }
        monitorFailureMessage = message
        if !diagnostics.contains(message) {
            diagnostics.append(message)
        }
        guard publishNotice, !isDuplicate else { return }

        let notice = LibghosttyConfigReloadNotice(
            kind: .error,
            message: """
            Automatic terminal configuration reload monitoring is degraded: \
            \(message)
            """
        )
        monitorFailureNoticeID = notice.id
        setConfigReloadNotice(notice)
    }

    private func clearMonitorFailure() {
        guard let message = monitorFailureMessage else { return }
        diagnostics.removeAll { $0 == message }
        monitorFailureMessage = nil
        if configReloadNotice?.id == monitorFailureNoticeID {
            setConfigReloadNotice(nil)
        }
        monitorFailureNoticeID = nil
    }

    private func setConfigReloadNotice(
        _ notice: LibghosttyConfigReloadNotice?
    ) {
        configReloadNotice = notice
        configReloadNoticeSubject.send(notice)
    }

    static func ensureLibraryInitialized() -> Bool {
        if didInitializeLibrary {
            return true
        }

        _ = LibghosttyEmbeddedResourcesLocator.configureEnvironmentIfNeeded()
        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard result == GHOSTTY_SUCCESS else {
            return false
        }

        Self.didInitializeLibrary = true
        return true
    }

    fileprivate nonisolated static func handleWakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let userdataValue = UInt(bitPattern: userdata)
        DispatchQueue.main.async {
            let state = runtime(from: userdataValue)
            state.runtimeState.recordWakeup()
            if let appHandle = state.appHandle {
                ghostty_app_tick(appHandle)
            }
        }
    }

    nonisolated static func handleAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let app else { return false }
        guard let userdata = ghostty_app_userdata(app) else { return false }
        let userdataValue = UInt(bitPattern: userdata)
        let sourceSurfaceIdentity = surfaceIdentity(from: target)

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.requestQuit()
            }
            return true

        case GHOSTTY_ACTION_OPEN_CONFIG:
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(.openConfig)
                NSWorkspace.shared.open(state.configPaths.globalConfigFile)
            }
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            let soft = action.action.reload_config.soft
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(.reloadConfig(soft: soft))
                // Always reload app-wide. The target struct contains a
                // raw ghostty_surface_t pointer that may be freed before
                // this async block runs (use-after-free). App-wide
                // reload also ensures all surfaces receive the update.
                state.reloadConfig(
                    projectRoot: state.activeConfigRoot,
                    force: true
                )
            }
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let sourceSurfaceIdentity,
                  let config = action.action.config_change.config,
                  let colors = resolvedTerminalColors(from: config),
                  let generation = resolvedColorGeneration(
                      from: userdataValue,
                      surfaceIdentity: sourceSurfaceIdentity
                  )
            else { return true }

            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.recordResolvedColors(
                    colors,
                    forSurfaceIdentity: sourceSurfaceIdentity,
                    generation: generation
                )
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(.ringBell)
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            let title = String(cString: action.action.set_title.title)
            let targetSurfaceIdentity = surfaceIdentity(from: target)
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                if let surfaceView = surfaceView(
                    fromSurfaceIdentity: targetSurfaceIdentity
                ) {
                    surfaceView.title = title
                }
                state.runtimeState.recordAction(.setTitle(title))
            }
            return true

        case GHOSTTY_ACTION_PWD:
            let path = String(cString: action.action.pwd.pwd)
            let targetSurfaceIdentity = surfaceIdentity(from: target)
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                if let surfaceView = surfaceView(
                    fromSurfaceIdentity: targetSurfaceIdentity
                ) {
                    surfaceView.pwd = path
                }
                state.runtimeState.recordAction(.workingDirectory(path))
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            handleOpenURL(action.action.open_url)
            return true

        case GHOSTTY_ACTION_NEW_SPLIT:
            let dir = splitDirection(from: action.action.new_split)
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(
                    .newSplit(dir),
                    sourceSurfaceIdentity: sourceSurfaceIdentity
                )
            }
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            let dir = gotoSplitDirection(from: action.action.goto_split)
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(
                    .gotoSplit(dir),
                    sourceSurfaceIdentity: sourceSurfaceIdentity
                )
            }
            return true

        case GHOSTTY_ACTION_RESIZE_SPLIT:
            let resizeAction = action.action.resize_split
            let dir = resizeSplitDirection(from: resizeAction.direction)
            let amount = resizeAction.amount
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(
                    .resizeSplit(dir, amount),
                    sourceSurfaceIdentity: sourceSurfaceIdentity
                )
            }
            return true

        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(
                    .equalizeSplits,
                    sourceSurfaceIdentity: sourceSurfaceIdentity
                )
            }
            return true

        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(
                    .toggleSplitZoom,
                    sourceSurfaceIdentity: sourceSurfaceIdentity
                )
            }
            return true

        case GHOSTTY_ACTION_RENDER:
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let surfacePtr = target.target.surface {
                let identity = UInt(bitPattern: surfacePtr)
                // Access renderTracker directly via raw pointer
                // — avoids @MainActor dispatch since the tracker
                // is Sendable and thread-safe.
                let userdata = UnsafeMutableRawPointer(
                    bitPattern: userdataValue
                )!
                let tracker = Unmanaged<LibghosttyRuntime>
                    .fromOpaque(userdata)
                    .takeUnretainedValue()
                    .renderTracker
                tracker.recordRender(surfaceIdentity: identity)
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let exitInfo = action.action.child_exited
            dispatchToMainSync {
                if let surfaceView = surfaceView(
                    fromSurfaceIdentity: sourceSurfaceIdentity
                ) {
                    surfaceView.childExitCode = exitInfo.exit_code
                }
            }
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(
                    .childExited(
                        exitCode: exitInfo.exit_code,
                        runtimeMS: exitInfo.timetime_ms
                    )
                )
            }
            return true

        case GHOSTTY_ACTION_START_SEARCH:
            let query = action.action.start_search.needle.map {
                String(cString: $0)
            } ?? ""
            guard let sourceSurfaceIdentity else { return true }
            let operation = LibghosttyFindOperationRegistry.shared
                .beginExternalOperation(for: sourceSurfaceIdentity)
            DispatchQueue.main.async {
                surfaceView(fromSurfaceIdentity: sourceSurfaceIdentity)?
                    .beginLibghosttyFind(query, operation: operation)
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            guard let sourceSurfaceIdentity,
                  let operation = LibghosttyFindOperationRegistry.shared
                  .operation(for: sourceSurfaceIdentity)
            else { return true }
            LibghosttyFindOperationRegistry.shared.removeOperation(
                for: sourceSurfaceIdentity
            )
            DispatchQueue.main.async {
                surfaceView(fromSurfaceIdentity: sourceSurfaceIdentity)?
                    .terminalFindController.backendDidEnd(
                        operation: operation
                    )
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = Int(action.action.search_total.total)
            guard let sourceSurfaceIdentity,
                  let operation = LibghosttyFindOperationRegistry.shared
                  .operation(for: sourceSurfaceIdentity)
            else { return true }
            DispatchQueue.main.async {
                surfaceView(fromSurfaceIdentity: sourceSurfaceIdentity)?
                    .publishLibghosttyFindTotal(
                        total,
                        operation: operation
                    )
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = Int(action.action.search_selected.selected)
            guard let sourceSurfaceIdentity,
                  let operation = LibghosttyFindOperationRegistry.shared
                  .operation(for: sourceSurfaceIdentity)
            else { return true }
            DispatchQueue.main.async {
                surfaceView(fromSurfaceIdentity: sourceSurfaceIdentity)?
                    .publishLibghosttyFindSelected(
                        selected,
                        operation: operation
                    )
            }
            return true

        default:
            DispatchQueue.main.async {
                let state = runtime(from: userdataValue)
                state.runtimeState.recordAction(
                    .unhandled(rawTag: Int32(bitPattern: action.tag.rawValue))
                )
            }
            return false
        }
    }

    fileprivate nonisolated static func handleReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        let userdataValue = userdata.map { UInt(bitPattern: $0) }
        let stateValue = state.map { UInt(bitPattern: $0) }
        // Track whether the request was actually completed.
        // dispatchToMainSync blocks, so the box is only read
        // after the closure finishes — no data race.
        final class Box: @unchecked Sendable { var value = false }
        let handled = Box()
        dispatchToMainSync {
            guard let surfaceView = surfaceView(from: userdataValue) else { return }
            guard let surfaceHandle = surfaceView.surfaceHandle else { return }
            let requestState = stateValue.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
            let request = requestState.map(ghostty_clipboard_request_type)

            // libghostty's semantic request is the authorization boundary.
            // User-configured paste bindings may read the clipboard, while
            // OSC 52 reads remain empty regardless of `clipboard-read`.
            let contents = clipboardReadContents(
                blocked: surfaceView.blocksClipboardReads,
                request: request,
                contents: TerminalPasteboardAccess.current.string(
                    forType: .string
                )
            )
            contents.withCString { ptr in
                ghostty_surface_complete_clipboard_request(
                    surfaceHandle, ptr, requestState, false
                )
            }
            handled.value = true
        }
        return handled.value
    }

    fileprivate nonisolated static func handleConfirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        let userdataValue = userdata.map { UInt(bitPattern: $0) }
        let stringValue = string.map { String(cString: $0) }
        let stateValue = state.map { UInt(bitPattern: $0) }
        dispatchToMainSync {
            guard let surfaceView = surfaceView(from: userdataValue) else { return }
            guard let surfaceHandle = surfaceView.surfaceHandle else { return }
            let requestState = stateValue.flatMap(UnsafeMutableRawPointer.init(bitPattern:))
            if !allowsClipboardConfirmation(
                blocked: surfaceView.blocksClipboardReads,
                request: request
            ) {
                "".withCString { buffer in
                    ghostty_surface_complete_clipboard_request(
                        surfaceHandle, buffer, requestState, true
                    )
                }
                return
            }
            guard let stringValue else { return }
            surfaceView.requestClipboardConfirmation(
                contents: stringValue,
                request: request
            ) { [surfaceView] approved in
                guard let surfaceHandle = surfaceView.surfaceHandle else {
                    return
                }
                let result = approved ? stringValue : ""
                result.withCString { buffer in
                    ghostty_surface_complete_clipboard_request(
                        surfaceHandle, buffer, requestState, true
                    )
                }
            }
        }
    }

    nonisolated static func handleWriteClipboard(
        userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        // Resolve userdata while libghostty still guarantees its lifetime.
        // The queued write captures this token across the async hop.
        let token = userdata.map {
            Unmanaged<SurfaceCallbackToken>.fromOpaque($0)
                .takeUnretainedValue()
        }
        let entries: [ClipboardWriteEntry] = (0 ..< len).compactMap { index in
            let item = content[index]
            guard let mimePtr = item.mime,
                  let dataPtr = item.data else {
                return nil
            }

            return ClipboardWriteEntry(
                mime: String(cString: mimePtr),
                data: String(cString: dataPtr)
            )
        }
        let isOSC52Write = entries.contains {
            $0.mime == osc52ClipboardWriteMIME
        }
        guard !confirm else {
            // Confirmed writes require user approval UI. Deny rather
            // than silently allowing remote clipboard overwrites.
            if isOSC52Write {
                DispatchQueue.main.async {
                    recordOSC52ClipboardWriteDiagnostic(
                        .confirmationRequired
                    )
                }
            }
            return
        }
        // libghostty may call this while holding its renderer lock. Waiting
        // synchronously for AppKit can deadlock with main-thread input events
        // that call back into the same surface.
        DispatchQueue.main.async {
            guard token?.view != nil else {
                if isOSC52Write {
                    recordOSC52ClipboardWriteDiagnostic(
                        .surfaceUnavailable
                    )
                }
                return
            }
            let diagnostic = writeClipboardEntries(
                entries,
                to: TerminalPasteboardAccess.current
            )
            if isOSC52Write {
                recordOSC52ClipboardWriteDiagnostic(diagnostic)
            }
        }
    }

    static func writeClipboardEntries(
        _ entries: [ClipboardWriteEntry],
        to pasteboard: any TerminalPasteboard
    ) -> OSC52ClipboardWriteDiagnostic {
        let writableEntries = acceptedClipboardWriteEntries(entries)
            .compactMap { entry -> (
                entry: ClipboardWriteEntry,
                type: NSPasteboard.PasteboardType
            )? in
                guard let type = pasteboardType(forMIMEType: entry.mime) else {
                    return nil
                }
                return (entry, type)
            }
        guard !writableEntries.isEmpty else {
            return .noWritableContent
        }

        pasteboard.clearContents()
        pasteboard.declareTypes(
            writableEntries.map(\.type),
            owner: nil
        )
        let byteCount = writableEntries.reduce(into: 0) { count, writable in
            count += writable.entry.data.utf8.count
        }
        let wroteEveryEntry = writableEntries.reduce(into: true) {
            wroteEveryEntry, writable in
            if !pasteboard.setString(
                writable.entry.data,
                forType: writable.type
            ) {
                wroteEveryEntry = false
            }
        }
        let entryCount = writableEntries.count
        if wroteEveryEntry {
            return .written(
                entryCount: entryCount,
                byteCount: byteCount
            )
        }
        return .pasteboardRejected(
            entryCount: entryCount,
            byteCount: byteCount
        )
    }

    private static func recordOSC52ClipboardWriteDiagnostic(
        _ diagnostic: OSC52ClipboardWriteDiagnostic
    ) {
        osc52ClipboardWriteDiagnosticObserver?(diagnostic)
        switch diagnostic {
        case .confirmationRequired:
            os_log(
                "OSC 52 clipboard write requires confirmation and was denied",
                log: osc52ClipboardLog,
                type: .error
            )
        case .surfaceUnavailable:
            os_log(
                "OSC 52 clipboard write arrived after its surface detached",
                log: osc52ClipboardLog,
                type: .error
            )
        case .noWritableContent:
            os_log(
                "OSC 52 clipboard write had no writable content",
                log: osc52ClipboardLog,
                type: .error
            )
        case let .pasteboardRejected(entryCount, byteCount):
            os_log(
                "OSC 52 pasteboard write failed: entries=%{public}d bytes=%{public}d",
                log: osc52ClipboardLog,
                type: .error,
                entryCount,
                byteCount
            )
        case let .written(entryCount, byteCount):
            os_log(
                "OSC 52 pasteboard write completed: entries=%{public}d bytes=%{public}d",
                log: osc52ClipboardLog,
                type: .info,
                entryCount,
                byteCount
            )
        }
    }

    static func clipboardReadContents(
        blocked: Bool,
        request: ghostty_clipboard_request_e?,
        contents: @autoclosure () -> String?
    ) -> String {
        // Do not even evaluate the pasteboard read for a remote surface.
        // Semantic paste is the sole exception; physical shortcuts are
        // resolved by libghostty before this callback is made.
        guard !blocked || request == GHOSTTY_CLIPBOARD_REQUEST_PASTE else {
            return ""
        }
        return contents() ?? ""
    }

    static func allowsClipboardConfirmation(
        blocked: Bool,
        request: ghostty_clipboard_request_e
    ) -> Bool {
        !blocked || request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
    }

    static func acceptedClipboardWriteEntries(
        _ entries: [ClipboardWriteEntry]
    ) -> [ClipboardWriteEntry] {
        entries.filter { $0.mime != osc52ClipboardWriteMIME }
    }

    static func pasteboardType(
        forMIMEType mimeType: String
    ) -> NSPasteboard.PasteboardType? {
        switch mimeType {
        case "text/plain":
            return .string
        default:
            break
        }

        if let type = UTType(mimeType: mimeType) {
            return NSPasteboard.PasteboardType(type.identifier)
        }

        return NSPasteboard.PasteboardType(mimeType)
    }

    fileprivate nonisolated static func handleCloseSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        let userdataValue = userdata.map { UInt(bitPattern: $0) }
        dispatchToMainSync {
            guard let surfaceView = surfaceView(from: userdataValue) else {
                return
            }
            if !processAlive {
                surfaceView.captureChildExitCode()
            }
            surfaceView.error = TerminalSurfaceError.surfaceClosed(
                processAlive: processAlive
            )
        }
    }

    fileprivate nonisolated static func handleChildWrite(
        userdata: UnsafeMutableRawPointer?,
        bytes: UnsafePointer<CChar>?,
        length: UInt
    ) {
        guard let bytes, length > 0, let userdata else { return }
        let data = Data(bytes: bytes, count: Int(length))
        // Resolve the callback token synchronously here, while the surface
        // (and therefore its userdata token) is guaranteed alive because
        // this callback is firing from it. Capturing the token strongly
        // across the async hop keeps it alive even if the owning view is
        // torn down before the block runs, so the weak view load on main
        // can never be a use-after-free — and a uniquely allocated token
        // can never resolve to a different view that reused an address.
        let token = Unmanaged<SurfaceCallbackToken>.fromOpaque(userdata)
            .takeUnretainedValue()
        DispatchQueue.main.async {
            guard let surfaceView = token.view else { return }
            surfaceView.onChildWrite?(data)
        }
    }

    @MainActor
    private static func surfaceView(
        from userdataValue: UInt?
    ) -> TerminalSurfaceView? {
        guard let userdataValue,
              let userdata = UnsafeMutableRawPointer(bitPattern: userdataValue)
        else { return nil }
        return Unmanaged<SurfaceCallbackToken>.fromOpaque(userdata)
            .takeUnretainedValue()
            .view
    }

    @MainActor
    private static func surfaceView(
        fromSurfaceIdentity identity: UInt?
    ) -> TerminalSurfaceView? {
        TerminalSurfaceView.surfaceView(forSurfaceIdentity: identity)
    }

    @MainActor
    private static func runtime(from userdataValue: UInt) -> LibghosttyRuntime {
        let userdata = UnsafeMutableRawPointer(bitPattern: userdataValue)!
        return Unmanaged<LibghosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    private nonisolated static func surfaceIdentity(
        from target: ghostty_target_s
    ) -> UInt? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface
        else { return nil }
        return UInt(bitPattern: surface)
    }

    nonisolated static func readBackgroundAppearance(
        from config: ghostty_config_t,
        increasedContrast: Bool
    ) -> TerminalBackgroundAppearance {
        // An absent or mismatched key leaves the out-parameter untouched,
        // so the pre-seeded values are the fallback defaults.
        var opacity = 1.0
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(
            config,
            &opacity,
            opacityKey,
            UInt(opacityKey.lengthOfBytes(using: .utf8))
        )

        var blur: Int16 = 0
        let blurKey = "background-blur"
        _ = ghostty_config_get(
            config,
            &blur,
            blurKey,
            UInt(blurKey.lengthOfBytes(using: .utf8))
        )

        return TerminalBackgroundAppearance(
            opacity: opacity,
            blurCValue: blur,
            increasedContrast: increasedContrast
        )
    }

    private nonisolated static func resolvedTerminalColors(
        from config: ghostty_config_t
    ) -> TerminalResolvedColors? {
        func color(for key: String) -> String? {
            var value = ghostty_config_color_s()
            guard ghostty_config_get(
                config,
                &value,
                key,
                UInt(key.lengthOfBytes(using: .utf8))
            ) else { return nil }
            return String(
                format: "#%02X%02X%02X",
                value.r,
                value.g,
                value.b
            )
        }

        guard let foreground = color(for: "foreground"),
              let background = color(for: "background")
        else { return nil }
        return TerminalResolvedColors(
            foreground: foreground,
            background: background
        )
    }

    private nonisolated static func dispatchToMainSync(
        _ operation: @MainActor @escaping () -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(operation)
            return
        }

        DispatchQueue.main.sync {
            MainActor.assumeIsolated(operation)
        }
    }

    private nonisolated static func resolvedColorGeneration(
        from userdataValue: UInt,
        surfaceIdentity: UInt
    ) -> ResolvedColorCallbackGeneration? {
        guard let pointer = UnsafeMutableRawPointer(bitPattern: userdataValue) else {
            return nil
        }
        let state = Unmanaged<LibghosttyRuntime>
            .fromOpaque(pointer)
            .takeUnretainedValue()
        return state.resolvedColorGenerations.snapshot(
            forSurface: surfaceIdentity
        )
    }

    nonisolated static func handleOpenURL(
        _ value: ghostty_action_open_url_s
    ) {
        let rawURL = String(
            decoding: UnsafeRawBufferPointer(
                start: value.url,
                count: Int(value.len)
            ),
            as: UTF8.self
        )
        DispatchQueue.main.async {
            openURL(rawURL)
        }
    }

    private static func openURL(_ rawURL: String) {
        let url: URL
        if let candidate = URL(string: rawURL), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: rawURL)
        }

        _ = urlOpener(url)
    }
}

private func splitDirection(
    from raw: ghostty_action_split_direction_e
) -> LibghosttySplitDirection {
    switch raw {
    case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
    case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
    case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
    case GHOSTTY_SPLIT_DIRECTION_UP: return .up
    default: return .unknown
    }
}

private func gotoSplitDirection(
    from raw: ghostty_action_goto_split_e
) -> LibghosttySplitDirection {
    switch raw {
    case GHOSTTY_GOTO_SPLIT_UP: return .up
    case GHOSTTY_GOTO_SPLIT_LEFT: return .left
    case GHOSTTY_GOTO_SPLIT_DOWN: return .down
    case GHOSTTY_GOTO_SPLIT_RIGHT: return .right
    default: return .unknown
    }
}

private func resizeSplitDirection(
    from raw: ghostty_action_resize_split_direction_e
) -> LibghosttySplitDirection {
    switch raw {
    case GHOSTTY_RESIZE_SPLIT_UP: return .up
    case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
    case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
    case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
    default: return .unknown
    }
}

private enum LibghosttyInitializationError: LocalizedError {
    case createConfig
    case createApp
    case unstableConfigGraph

    var errorDescription: String? {
        switch self {
        case .createConfig:
            return "ghostty_config_new failed"
        case .createApp:
            return "ghostty_app_new failed"
        case .unstableConfigGraph:
            return "Terminal configuration changed repeatedly while reloading."
        }
    }
}

private func ghosttyRuntimeWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    LibghosttyRuntime.handleWakeup(userdata)
}

private func ghosttyRuntimeActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    LibghosttyRuntime.handleAction(app: app, target: target, action: action)
}

private func ghosttyRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    LibghosttyRuntime.handleReadClipboard(userdata: userdata, location: location, state: state)
}

private func ghosttyRuntimeConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    LibghosttyRuntime.handleConfirmReadClipboard(
        userdata: userdata,
        string: string,
        state: state,
        request: request
    )
}

private func ghosttyRuntimeWriteClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ content: UnsafePointer<ghostty_clipboard_content_s>?,
    _ len: Int,
    _ confirm: Bool
) {
    LibghosttyRuntime.handleWriteClipboard(
        userdata: userdata,
        location: location,
        content: content,
        len: len,
        confirm: confirm
    )
}

private func ghosttyRuntimeCloseSurfaceCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ processAlive: Bool
) {
    LibghosttyRuntime.handleCloseSurface(userdata: userdata, processAlive: processAlive)
}

private func ghosttyRuntimeChildWriteCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ length: UInt
) {
    LibghosttyRuntime.handleChildWrite(userdata: userdata, bytes: bytes, length: length)
}
