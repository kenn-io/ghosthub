import AppKit
import Combine
import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace
import GhosttyKit
import UniformTypeIdentifiers

@MainActor
public final class GhosttyRuntime: ObservableObject {
    struct ClipboardWriteEntry: Equatable {
        let mime: String
        let data: String
    }

    static let osc52ClipboardWriteMIME = "application/x-ghosthub-osc52"

    public static let shared = GhosttyRuntime(
        pipeline: GhosttyConfigPipeline(
            paths: GhosttyConfigPaths(
                configDirectory: ConfigHome.resolved()
            )
        )
    )

    @Published public private(set) var bootstrapStatus: GhosttyBootstrapStatus
    @Published public private(set) var phase: GhosttyRuntimePhase
    @Published public private(set) var configPlan: GhosttyConfigLoadPlan?
    @Published public private(set) var diagnostics: [String]

    public let runtimeState: GhosttyRuntimeState
    public let renderTracker = SurfaceRenderTracker()

    private let pipeline: GhosttyConfigPipeline
    private nonisolated(unsafe) var appHandle: ghostty_app_t?
    private nonisolated(unsafe) var configHandle: ghostty_config_t?
    private var activeConfigRoot: URL?
    private var configMonitor: GhosttyConfigFileMonitor?
    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private static var didInitializeLibrary = false

    public var configPaths: GhosttyConfigPaths {
        pipeline.paths
    }

    public var needsConfirmQuit: Bool {
        guard let appHandle else { return false }
        return ghostty_app_needs_confirm_quit(appHandle)
    }

    var unsafeAppHandle: ghostty_app_t? {
        appHandle
    }

    public init(
        pipeline: GhosttyConfigPipeline = .live,
        runtimeState: GhosttyRuntimeState? = nil
    ) {
        self.pipeline = pipeline
        self.runtimeState = runtimeState ?? GhosttyRuntimeState()
        bootstrapStatus = .ready()
        phase = .loadingConfig
        diagnostics = []

        initializeGhostty()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
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
            let message = bootstrapStatus.message ?? "Ghostty failed to initialize."
            preconditionFailure(message, file: file, line: line)
        }
    }

    public func reloadConfig(projectRoot: URL? = nil, force: Bool = false) {
        reloadConfig(target: nil, projectRoot: projectRoot, force: force)
    }

    public func reloadActiveConfig(force: Bool = true) {
        reloadConfig(projectRoot: activeConfigRoot, force: force)
    }

    public func reloadConfig(
        target: ghostty_target_s?,
        projectRoot: URL? = nil,
        force: Bool = false
    ) {
        guard let appHandle else { return }
        guard force || activeConfigRoot != projectRoot else { return }
        activeConfigRoot = projectRoot

        do {
            let plan = try pipeline.loadPlan(projectRoot: projectRoot)
            let config = try loadConfig(plan: plan)
            configPlan = plan
            diagnostics = readDiagnostics(from: config)

            if let target,
               target.tag == GHOSTTY_TARGET_SURFACE,
               let surfaceHandle = target.target.surface {
                ghostty_surface_update_config(surfaceHandle, config)
                ghostty_config_free(config)
            } else {
                ghostty_app_update_config(appHandle, config)
                replaceConfigHandle(with: config)
            }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            diagnostics = [error.localizedDescription]
        }
    }

    private func initializeGhostty() {
        guard Self.ensureLibraryInitialized() else {
            bootstrapStatus = .missing(
                message: "libghostty failed to initialize. Re-run `make bootstrap-libghostty` and relaunch Ghosthub."
            )
            phase = .failed("ghostty_init failed")
            diagnostics = ["ghostty_init failed"]
            return
        }

        do {
            let plan = try pipeline.loadPlan()
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
                throw GhosttyInitializationError.createApp
            }

            self.appHandle = appHandle
            ghostty_app_keyboard_changed(appHandle)
            ghostty_app_set_focus(appHandle, NSApplication.shared.isActive)
            replaceConfigHandle(with: config)
            configPlan = plan
            diagnostics = readDiagnostics(from: config)
            installApplicationObservers()
            installConfigMonitorIfNeeded()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
            diagnostics = [error.localizedDescription]
        }
    }

    private func loadConfig(plan: GhosttyConfigLoadPlan) throws -> ghostty_config_t {
        guard let config = ghostty_config_new() else {
            throw GhosttyInitializationError.createConfig
        }

        try loadConfigFiles(plan: plan, into: config)
        ghostty_config_finalize(config)
        return config
    }

    private func loadConfigFiles(
        plan: GhosttyConfigLoadPlan,
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
        // we do not need Ghostty's default file discovery at all.
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
    }

    private func installConfigMonitorIfNeeded() {
        guard configMonitor == nil else { return }

        let monitor = GhosttyConfigFileMonitor(fileURL: configPaths
            .globalConfigFile) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.reloadConfig(projectRoot: self.activeConfigRoot, force: true)
                }
            }

        do {
            try monitor.start()
            configMonitor = monitor
        } catch {
            diagnostics.append(error.localizedDescription)
        }
    }

    private static func ensureLibraryInitialized() -> Bool {
        if didInitializeLibrary {
            return true
        }

        _ = GhosttyEmbeddedResourcesLocator.configureEnvironmentIfNeeded()
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

    fileprivate nonisolated static func handleAction(
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
                state.runtimeState.recordAction(.quit)
                NSApplication.shared.terminate(nil)
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
            let openURLAction = action.action.open_url
            DispatchQueue.main.async {
                Self.openURL(openURLAction)
            }
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
                let tracker = Unmanaged<GhosttyRuntime>
                    .fromOpaque(userdata)
                    .takeUnretainedValue()
                    .renderTracker
                tracker.recordRender(surfaceIdentity: identity)
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let exitInfo = action.action.child_exited
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

            // Ghostty identifies the request type only after this callback.
            // A config such as `clipboard-read = allow` can skip the later
            // confirmation callback entirely, so a remote surface must never
            // receive the real pasteboard value here. Explicit user paste is
            // handled directly by TerminalSurfaceView instead.
            let contents = clipboardReadContents(
                blocked: surfaceView.blocksClipboardAccess,
                contents: NSPasteboard.general.string(forType: .string)
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
                blocked: surfaceView.blocksClipboardAccess,
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

            stringValue.withCString { buffer in
                ghostty_surface_complete_clipboard_request(
                    surfaceHandle, buffer, requestState, true
                )
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
        guard !confirm else {
            // Confirmed writes require user approval UI. Deny rather
            // than silently allowing remote clipboard overwrites.
            return
        }
        let userdataValue = userdata.map { UInt(bitPattern: $0) }
        guard let content, len > 0 else { return }
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
        dispatchToMainSync {
            guard let surfaceView = surfaceView(from: userdataValue),
                  let acceptedEntries = acceptedClipboardWriteEntries(
                      blocked: surfaceView.blocksClipboardAccess,
                      entries: entries
                  ) else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let types = acceptedEntries.compactMap {
                pasteboardType(forMIMEType: $0.mime)
            }
            pasteboard.declareTypes(types, owner: nil)
            for entry in acceptedEntries {
                guard let type = pasteboardType(forMIMEType: entry.mime) else {
                    continue
                }
                pasteboard.setString(entry.data, forType: type)
            }
        }
    }

    static func clipboardReadContents(
        blocked: Bool,
        contents: @autoclosure () -> String?
    ) -> String {
        // Do not even evaluate the pasteboard read for a remote surface.
        // Supplying an empty value here makes the boundary independent of
        // Ghostty's user-configurable clipboard confirmation policy.
        guard !blocked else { return "" }
        return contents() ?? ""
    }

    static func allowsClipboardConfirmation(
        blocked: Bool,
        request: ghostty_clipboard_request_e
    ) -> Bool {
        !blocked || request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
    }

    static func acceptedClipboardWriteEntries(
        blocked: Bool,
        entries: [ClipboardWriteEntry]
    ) -> [ClipboardWriteEntry]? {
        let isOSC52 = entries.contains { $0.mime == osc52ClipboardWriteMIME }
        guard !blocked || !isOSC52 else { return nil }
        return entries.filter { $0.mime != osc52ClipboardWriteMIME }
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
    private static func runtime(from userdataValue: UInt) -> GhosttyRuntime {
        let userdata = UnsafeMutableRawPointer(bitPattern: userdataValue)!
        return Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
    }

    private nonisolated static func surfaceIdentity(
        from target: ghostty_target_s
    ) -> UInt? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface
        else { return nil }
        return UInt(bitPattern: surface)
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

    @MainActor
    private static func openURL(_ value: ghostty_action_open_url_s) {
        let rawURL = String(cString: value.url)
        let url: URL
        if let candidate = URL(string: rawURL), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: rawURL)
        }

        NSWorkspace.shared.open(url)
    }
}

private func splitDirection(
    from raw: ghostty_action_split_direction_e
) -> GhosttySplitDirection {
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
) -> GhosttySplitDirection {
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
) -> GhosttySplitDirection {
    switch raw {
    case GHOSTTY_RESIZE_SPLIT_UP: return .up
    case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
    case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
    case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
    default: return .unknown
    }
}

private enum GhosttyInitializationError: LocalizedError {
    case createConfig
    case createApp

    var errorDescription: String? {
        switch self {
        case .createConfig:
            return "ghostty_config_new failed"
        case .createApp:
            return "ghostty_app_new failed"
        }
    }
}

private func ghosttyRuntimeWakeupCallback(_ userdata: UnsafeMutableRawPointer?) {
    GhosttyRuntime.handleWakeup(userdata)
}

private func ghosttyRuntimeActionCallback(
    _ app: ghostty_app_t?,
    _ target: ghostty_target_s,
    _ action: ghostty_action_s
) -> Bool {
    GhosttyRuntime.handleAction(app: app, target: target, action: action)
}

private func ghosttyRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyRuntime.handleReadClipboard(userdata: userdata, location: location, state: state)
}

private func ghosttyRuntimeConfirmReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ string: UnsafePointer<CChar>?,
    _ state: UnsafeMutableRawPointer?,
    _ request: ghostty_clipboard_request_e
) {
    GhosttyRuntime.handleConfirmReadClipboard(
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
    GhosttyRuntime.handleWriteClipboard(
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
    GhosttyRuntime.handleCloseSurface(userdata: userdata, processAlive: processAlive)
}

private func ghosttyRuntimeChildWriteCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ bytes: UnsafePointer<CChar>?,
    _ length: UInt
) {
    GhosttyRuntime.handleChildWrite(userdata: userdata, bytes: bytes, length: length)
}
