import AppKit
import Combine
import CoreText
import Darwin
import GhosttyKit
import GhosthubTerminalSupport

private struct PendingLibghosttyKeyInput: @unchecked Sendable {
    let surfaceAddress: UInt
    let keyEvent: ghostty_input_key_s
    let text: String?

    func send() {
        guard let surface = ghostty_surface_t(bitPattern: surfaceAddress)
        else { return }

        if let text, !text.isEmpty,
           let codepoint = text.utf8.first, codepoint >= 0x20 {
            text.withCString { ptr in
                var keyEventWithText = keyEvent
                keyEventWithText.text = ptr
                _ = ghostty_surface_key(surface, keyEventWithText)
            }
        } else {
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }
}

/// Stable, per-surface identity handed to libghostty as the callback
/// `userdata`. Unlike a raw view address, a freshly allocated token is
/// unique for its view's lifetime and stays alive until after
/// `ghostty_surface_free` returns, so a queued callback can never resolve
/// to a different view that happened to reuse a dead view's address.
///
/// `@unchecked Sendable`: the sole stored property is a `weak var`, whose
/// loads and stores are atomic and thread-safe. Callbacks resolve the
/// token on a background thread and read `.view` on main; nothing mutates
/// it except ARC zeroing on the owning view's dealloc.
final class SurfaceCallbackToken: @unchecked Sendable {
    weak var view: TerminalSurfaceView?

    init(view: TerminalSurfaceView) {
        self.view = view
    }
}

@MainActor
public final class TerminalSurfaceView: NSView, ObservableObject {
    static var occlusionSetter: (ghostty_surface_t, Bool) -> Void = {
        surface, visible in
        ghostty_surface_set_occlusion(surface, visible)
    }
    static var focusSetter: (ghostty_surface_t, Bool) -> Void = {
        surface, focused in
        ghostty_surface_set_focus(surface, focused)
    }
    static var sizeSetter: (ghostty_surface_t, UInt32, UInt32) -> Void = {
        surface, width, height in
        ghostty_surface_set_size(surface, width, height)
    }
    static var contentScaleSetter: (ghostty_surface_t, Double, Double) -> Void = {
        surface, xScale, yScale in
        ghostty_surface_set_content_scale(surface, xScale, yScale)
    }
    typealias ClipboardConfirmationPresenter = (
        _ view: TerminalSurfaceView,
        _ contents: String,
        _ request: ghostty_clipboard_request_e,
        _ completion: @escaping (Bool) -> Void
    ) -> Void
    static var clipboardConfirmationPresenter:
        ClipboardConfirmationPresenter?

    private final class WeakSurfaceReference {
        weak var view: TerminalSurfaceView?

        init(view: TerminalSurfaceView) {
            self.view = view
        }
    }

    private static var viewsBySurfaceIdentity: [UInt: WeakSurfaceReference] = [:]

    // MARK: - Published State

    @Published public internal(set) var title: String = ""
    @Published public var pwd: String?
    public internal(set) var childExitCode: UInt32?
    @Published public var cellSize: NSSize = .zero
    @Published public var surfaceSize: ghostty_surface_size_s?
    @Published public private(set) var healthy: Bool = true
    @Published public internal(set) var error: Error? {
        didSet {
            guard let terminalError = error as? TerminalSurfaceError else {
                return
            }
            switch terminalError {
            case let .surfaceClosed(processAlive):
                onSurfaceClosed?(processAlive)
                for observer in surfaceCloseObservers.values {
                    observer(processAlive)
                }
            case .surfaceCreationFailed:
                break
            }
        }
    }

    /// True when libghostty could not create this surface with no active display.
    ///
    /// That specific failure is transient: the renderer needs an active display
    /// to build its vsync display link. Other creation failures may persist, so
    /// callers must not keep recovering from them indefinitely.
    public var launchFailureIsRetryable: Bool {
        guard let terminalError = error as? TerminalSurfaceError else {
            return false
        }
        if case let .surfaceCreationFailed(activeDisplayCount) = terminalError {
            return DisplayAvailability.surfaceCreationFailureIsRetryable(
                activeDisplayCount: activeDisplayCount
            )
        }
        return false
    }

    // MARK: - Internal State

    @Published public private(set) var focused: Bool = false

    /// When true, the surface will not automatically claim first
    /// responder in viewDidMoveToWindow or windowDidBecomeKey.
    /// Set by the pane view when the split controller says this
    /// leaf is no longer focused.
    public var suppressAutoFocus: Bool = false
    public private(set) var isParkedForPreview = false

    /// Unique per-surface identity handed to libghostty as `userdata`. Held
    /// strongly here for the view's lifetime and re-captured by the
    /// deferred teardown Task so it outlives the last possible callback.
    private(set) nonisolated(unsafe) var callbackToken: SurfaceCallbackToken!
    private nonisolated(unsafe) var surface: ghostty_surface_t?
    private nonisolated(unsafe) var keyInputQueue =
        DispatchQueue(
            label: "com.ghosthub.terminal.key-input",
            qos: .userInteractive
        )
    var prevPressureStage: Int = 0
    lazy var mouseEventHandler = TerminalMouseEventHandler(
        delegate: self
    )
    lazy var textInputHandler = TerminalTextInputHandler(
        delegate: self
    )
    private var appearanceObserver: NSKeyValueObservation?
    private nonisolated(unsafe) var eventMonitor: Any?
    var lastPerformKeyEvent: TimeInterval?
    private var consumedCommandKeyCodes: Set<UInt16> = []
    private var consumedPaneSplitKeyCodes: Set<UInt16> = []
    private var surfaceResizeState = SurfaceResizeState()
    private var previewGridSize: (columns: Int, rows: Int)?
    private var isDeferringLiveResize = false
    private var isDeferringPresentationResize = false
    private var isDeferringSurfaceResize: Bool {
        isDeferringLiveResize || isDeferringPresentationResize
    }
    private var hasSyncedFocusState = false
    private let keyEventInterpreter: (([NSEvent]) -> Void)?
    let textInputObserver: ((String) -> Void)?
    let commandObserver: ((Selector) -> Void)?
    public var onFocusChange: ((Bool) -> Void)?
    public var onPrimaryInteraction: (() -> Void)?
    public var onCloseRequest: (() -> Void)?
    public var shouldConfirmClose: (() -> Bool)?
    @Published public var paneSplitErrorMessage: String?
    /// Installed only for native session surfaces whose backend supports
    /// semantic pane splitting.
    public var paneSplitShortcutHandler: ((TerminalPaneSplitShortcut) -> Void)?
    public var applicationShortcutsProvider:
        (() -> ResolvedApplicationShortcuts)?
    /// Control-mode surfaces render through a silent local child, so their
    /// meaningful process liveness comes from the tmux pane rather than
    /// `childProcessID`. When supplied, close confirmation uses this source.
    public var hasRunningChildProcessOverride: (() -> Bool)?
    public var onSurfaceClosed: ((Bool) -> Void)?
    /// When set, this surface is pane-routed: encodable non-Cmd key events,
    /// IME-committed text, and pane-routed paste go here instead of the
    /// local libghostty core (`AttachedTmuxInputRouter`/`AttachedTmuxInputEncoder`
    /// in `AttachedTmuxInput.swift`). This legacy hook has no production setter
    /// after native tmux attachment replaced pane projection.
    /// Diverges from fantastty: fantastty stores `tmuxPaneID` /
    /// `weak tmuxControlClient` directly on the surface view; ghosthub keeps
    /// tmux types out of GhosthubTerminal, so this single closure is the
    /// boundary instead.
    public var tmuxPaneInputSink: ((Data) -> Void)?
    /// Routes clipboard paste through tmux's paste buffer so tmux can honor
    /// the pane application's bracketed-paste mode.
    public var tmuxPanePasteSink: ((Data) -> Void)?
    /// Remote tmux surfaces must not read from or write to the local Mac
    /// clipboard through terminal escape sequences. Explicit user paste
    /// remains available because libghostty labels semantic paste requests
    /// before the runtime reads the pasteboard.
    public var blocksClipboardReads = false
    private var isClipboardConfirmationPending = false
    private var tmuxTerminalModeTracker = AttachedTmuxTerminalModeTracker()
    /// The surface's grid dimensions (columns, rows) changed. Task-8 addition:
    /// control mode uses this to feed pane resizes back to tmux (per-pane
    /// `paneSurfaceDidResize` plus the client `refresh-client -C`). The grid
    /// size is already reported to libghostty via `ghostty_surface_size`; this
    /// just relays the cell dimensions to Swift consumers.
    public var onGridSizeChanged: ((Int, Int) -> Void)?
    package var onSurfaceDestroyed: (@MainActor @Sendable (UInt) -> Void)?
    var fontZoomShortcutHandler: ((TerminalFontZoomCommand) -> Bool)?
    private var focusObservers: [UUID: (Bool) -> Void] = [:]
    private var primaryInteractionObservers: [UUID: () -> Void] = [:]
    private var closeRequestObservers: [UUID: () -> Void] = [:]
    private var surfaceCloseObservers: [UUID: (Bool) -> Void] = [:]

    override public var acceptsFirstResponder: Bool {
        !isParkedForPreview
    }

    override public var canBecomeKeyView: Bool {
        !isParkedForPreview
    }

    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        false
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            if focused {
                focusDidChange(false)
            }
            setSurfaceOcclusion(false)
            return
        }
        if !isParkedForPreview,
           !applyPreviewGridSize(),
           bounds.size.width > 0, bounds.size.height > 0 {
            handleSizeChange(bounds.size)
        }
        syncInitialOcclusionState(for: window)
        guard !isParkedForPreview,
              !suppressAutoFocus,
              window.isKeyWindow
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.suppressAutoFocus,
                  let currentWindow = self.window,
                  currentWindow === window,
                  currentWindow.isKeyWindow else { return }
            if isCompetingFirstResponder(window.firstResponder) {
                return
            }
            ensureFirstResponder()
        }
    }

    // MARK: - Initialization

    init(
        app: ghostty_app_t,
        configuration: TerminalSurfaceConfiguration,
        keyEventInterpreter: (([NSEvent]) -> Void)? = nil,
        textInputObserver: ((String) -> Void)? = nil,
        commandObserver: ((Selector) -> Void)? = nil
    ) {
        self.keyEventInterpreter = keyEventInterpreter
        self.textInputObserver = textInputObserver
        self.commandObserver = commandObserver
        super.init(frame: NSMakeRect(0, 0, 800, 600))
        callbackToken = SurfaceCallbackToken(view: self)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onUpdateRendererHealth),
            name: Notification.Name("com.ghostty.rendererHealth"),
            object: self
        )
        center.addObserver(
            self,
            selector: #selector(windowDidChangeScreen),
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowDidChangeOcclusionState),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .leftMouseDown]
        ) { [weak self] event in self?.localEventHandler(event) }

        let surfaceHandle = configuration.withCValue(view: self) { config in
            ghostty_surface_new(app, &config)
        }
        guard let surfaceHandle else {
            error = TerminalSurfaceError.surfaceCreationFailed(
                activeDisplayCount: DisplayAvailability.activeCount()
            )
            return
        }
        surface = surfaceHandle
        let surfaceIdentity = UInt(bitPattern: surfaceHandle)
        Self.viewsBySurfaceIdentity[surfaceIdentity] =
            WeakSurfaceReference(view: self)

        updateTrackingAreas()
        installAppearanceObserver()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        let monitor = eventMonitor
        let surfaceHandle = surface
        let queue = keyInputQueue
        let token = callbackToken
        let onSurfaceDestroyed = onSurfaceDestroyed
        NotificationCenter.default.removeObserver(self)

        if let monitor {
            NSEvent.removeMonitor(monitor)
        }

        if let surfaceHandle {
            let surfaceIdentity = UInt(bitPattern: surfaceHandle)
            // Drain pending key events before freeing the surface to
            // prevent use-after-free on the background queue, then free
            // the surface. `ghostty_surface_free` stops all surface
            // callbacks before returning, so keeping `token` alive across
            // the free (via `withExtendedLifetime` below) guarantees no
            // in-flight callback can resolve a dangling token afterward.
            Task.detached { @MainActor in
                queue.sync {}
                Self.viewsBySurfaceIdentity.removeValue(
                    forKey: surfaceIdentity
                )
                onSurfaceDestroyed?(surfaceIdentity)
                ghostty_surface_free(surfaceHandle)
                withExtendedLifetime(token) {}
            }
        }
    }

    // MARK: - Public API

    package var surfaceHandle: ghostty_surface_t? { surface }

    package var surfaceIdentity: UInt? {
        surfaceHandle.map { UInt(bitPattern: $0) }
    }

    package func captureChildExitCode() {
        guard childExitCode == nil, let surface else { return }
        let exitCode = ghostty_surface_child_exit_code(surface)
        guard exitCode >= 0 else { return }
        childExitCode = UInt32(exitCode)
    }

    package func synchronizeColorScheme() {
        guard let surface else { return }
        let scheme: ghostty_color_scheme_e
        switch effectiveAppearance.name {
        case .aqua, .vibrantLight:
            scheme = GHOSTTY_COLOR_SCHEME_LIGHT
        case .darkAqua, .vibrantDark:
            scheme = GHOSTTY_COLOR_SCHEME_DARK
        default:
            return
        }
        ghostty_surface_set_color_scheme(surface, scheme)
    }

    package static func surfaceView(
        forSurfaceIdentity identity: UInt?
    ) -> TerminalSurfaceView? {
        guard let identity else {
            return nil
        }
        if let view = viewsBySurfaceIdentity[identity]?.view {
            return view
        }
        viewsBySurfaceIdentity.removeValue(forKey: identity)
        return nil
    }

    public var childProcessID: pid_t? {
        guard let surface else { return nil }
        let pid = ghostty_surface_child_pid(surface)
        return pid > 0 ? pid_t(pid) : nil
    }

    var currentFontSizePoints: CGFloat? {
        guard let surface,
              let fontRef = ghostty_surface_quicklook_font(surface)
        else {
            return nil
        }
        // ghostty_surface_quicklook_font returns an owned +1 CTFont.
        let font = Unmanaged<CTFont>.fromOpaque(fontRef)
            .takeRetainedValue()
        return CGFloat(CTFontGetSize(font))
    }

    public func focusDidChange(_ newFocused: Bool) {
        let newFocused = newFocused && !isParkedForPreview
        guard let surface else { return }
        let stateChanged = focused != newFocused
        guard stateChanged || !hasSyncedFocusState else { return }
        focused = newFocused
        hasSyncedFocusState = true
        if !newFocused {
            consumedCommandKeyCodes.removeAll()
        }
        if stateChanged {
            onFocusChange?(newFocused)
            for observer in focusObservers.values {
                observer(newFocused)
            }
        }
        // Pane-routed surfaces never own tmux focus; suppressing the core
        // focus call keeps the silent child from receiving focus reports.
        guard tmuxPaneInputSink == nil else { return }
        Self.focusSetter(surface, newFocused)
    }

    override public func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !isParkedForPreview,
              window != nil,
              newSize.width > 0, newSize.height > 0
        else { return }
        handleSizeChange(newSize)
    }

    public func sizeDidChange(_ size: CGSize) {
        handleSizeChange(size)
    }

    func setPresentationResizeDeferred(_ deferred: Bool) {
        guard isDeferringPresentationResize != deferred else { return }
        isDeferringPresentationResize = deferred
        if !isDeferringSurfaceResize {
            flushPendingSurfaceResize()
        }
    }

    private func handleSizeChange(_ size: CGSize) {
        let scaledSize = convertToBacking(size)
        guard let pixelSize = SurfacePixelSize(scaledSize) else { return }
        let width = pixelSize.width
        let height = pixelSize.height
        guard surfaceResizeState.needsResize(
            width: width,
            height: height
        ) else { return }

        switch SurfaceResizePolicy.decision(
            isLiveResize: isDeferringSurfaceResize
        ) {
        case .immediate:
            applySurfaceSize(width: width, height: height)

        case .deferredUntilLiveResizeEnds:
            surfaceResizeState.setPending(
                width: width,
                height: height
            )
        }
    }

    // MARK: - Private Helpers

    private func setSurfaceSize(width: UInt32, height: UInt32) {
        guard let surface else { return }
        Self.sizeSetter(surface, width, height)
        let size = ghostty_surface_size(surface)
        let gridChanged = surfaceSize?.columns != size.columns
            || surfaceSize?.rows != size.rows
        let pixelsChanged = surfaceSize?.width_px != size.width_px
            || surfaceSize?.height_px != size.height_px
        guard gridChanged || pixelsChanged else { return }
        surfaceSize = size
        if gridChanged, size.columns > 0, size.rows > 0 {
            onGridSizeChanged?(Int(size.columns), Int(size.rows))
        }
    }

    /// Recomputes cell geometry without requiring the view's pixel bounds to
    /// change. Runtime font zoom changes the number of rows and columns that
    /// fit in the existing bounds, so control-mode panes must report a fresh
    /// grid to tmux immediately after the binding action lands.
    func refreshGridSize() {
        if previewGridSize != nil, applyPreviewGridSize() {
            return
        }
        let backingSize = convertToBacking(bounds.size)
        guard let pixelSize = SurfacePixelSize(backingSize) else { return }
        setSurfaceSize(
            width: pixelSize.width,
            height: pixelSize.height
        )
    }

    private func applySurfaceSize(
        width: UInt32,
        height: UInt32
    ) {
        surfaceResizeState.apply(
            width: width,
            height: height
        )
        setSurfaceSize(width: width, height: height)
    }

    private func flushPendingSurfaceResize() {
        guard let pendingSurfacePixelSize = surfaceResizeState.consumePending() else {
            return
        }
        applySurfaceSize(
            width: pendingSurfacePixelSize.width,
            height: pendingSurfacePixelSize.height
        )
    }

    public func requestKeyboardFocus() {
        guard !isParkedForPreview else { return }
        ensureFirstResponder()
    }

    public func setParkedForPreview(_ parked: Bool) {
        guard isParkedForPreview != parked else { return }
        if parked {
            suppressAutoFocus = true
            mouseEventHandler.resetPointerStateForParking()
            isParkedForPreview = true
            updateTrackingAreas()
            if window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
            focusDidChange(false)
        } else {
            isParkedForPreview = false
            updateTrackingAreas()
        }
    }

    /// Completes a preview mount after AppKit has finished reparenting the
    /// view. Automatic backing and frame callbacks stay suppressed while a
    /// surface is parked: their intermediate geometry is not a valid terminal
    /// DPI or resize source, and parked previews do not need to track window
    /// layout changes.
    public func completePreviewParkingMount() {
        guard isParkedForPreview, let window else { return }
        let contentScale = window.backingScaleFactor
        guard contentScale.isFinite,
              contentScale >= 1,
              contentScale <= 8
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = contentScale
        CATransaction.commit()
        if let surface {
            Self.contentScaleSetter(surface, contentScale, contentScale)
        }
        _ = applyPreviewGridSize()
    }

    /// Sizes a hidden preview surface to the tmux window's existing grid.
    /// The preview client must have tmux's `ignore-size` flag while this is
    /// applied so the local rendering surface cannot change the shared window.
    @discardableResult
    public func sizeForPreviewGrid(columns: Int, rows: Int) -> Bool {
        guard columns > 0, rows > 0 else { return false }
        previewGridSize = (columns, rows)
        return applyPreviewGridSize()
    }

    @discardableResult
    private func applyPreviewGridSize() -> Bool {
        guard let surface, let previewGridSize else {
            return false
        }
        let current = ghostty_surface_size(surface)
        guard current.columns > 0, current.rows > 0,
              current.width_px > 0, current.height_px > 0,
              current.cell_width_px > 0, current.cell_height_px > 0
        else { return false }
        let horizontalSlack = Int64(current.width_px)
            - Int64(current.cell_width_px) * Int64(current.columns)
        let verticalSlack = Int64(current.height_px)
            - Int64(current.cell_height_px) * Int64(current.rows)
        let targetWidth = Int64(current.cell_width_px)
            * Int64(previewGridSize.columns) + horizontalSlack
        let targetHeight = Int64(current.cell_height_px)
            * Int64(previewGridSize.rows) + verticalSlack
        guard targetWidth > 0,
              targetHeight > 0,
              targetWidth <= Int64(UInt32.max),
              targetHeight <= Int64(UInt32.max)
        else { return false }
        let backingSize = NSSize(
            width: CGFloat(targetWidth),
            height: CGFloat(targetHeight)
        )
        guard SurfacePixelSize(backingSize) != nil else { return false }
        applySurfaceSize(
            width: UInt32(targetWidth),
            height: UInt32(targetHeight)
        )
        if let window {
            let targetSize = window.convertFromBacking(
                NSRect(origin: .zero, size: backingSize)
            ).size
            guard targetSize.width.isFinite,
                  targetSize.height.isFinite,
                  targetSize.width > 0,
                  targetSize.height > 0
            else {
                return false
            }
            setFrameSize(targetSize)
        }
        return true
    }

    /// Inject bytes into the terminal as OUTPUT (as if read from the pty).
    /// Used by tmux control mode. Returns false if the surface is gone.
    /// Safe to call only from the main thread (matches surface lifecycle).
    public func injectOutput(_ data: Data) -> Bool {
        guard let surface else { return false }
        if tmuxPaneInputSink != nil {
            tmuxTerminalModeTracker.consume(data)
        }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            ghostty_surface_inject_output(
                surface,
                base.assumingMemoryBound(to: CChar.self),
                UInt(buffer.count)
            )
        }
        return true
    }

    public func setTmuxApplicationCursorKeys(_ enabled: Bool) {
        tmuxTerminalModeTracker.setApplicationCursorKeys(enabled)
    }

    /// Bytes the terminal wrote toward its child process (mouse reports,
    /// query responses). Control mode forwards these to tmux as send-keys.
    /// Delivered async on the main queue.
    public var onChildWrite: ((Data) -> Void)?

    public func sendProgrammaticInput(_ string: String) {
        guard surface != nil else { return }
        let chars = string
        let len = chars.utf8CString.count
        guard len > 0 else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
    }

    public func sendProgrammaticReturn() {
        guard surface != nil else { return }
        guard let keyDownEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else {
            return
        }
        let keyUpEvent = NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: [],
            timestamp: keyDownEvent.timestamp,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )

        _ = keyAction(GHOSTTY_ACTION_PRESS, event: keyDownEvent)
        if let keyUpEvent {
            _ = keyAction(GHOSTTY_ACTION_RELEASE, event: keyUpEvent)
        }
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ptr in
            ghostty_surface_binding_action(
                surface,
                ptr,
                UInt(action.utf8.count)
            )
        }
    }

    public func registerPaneFocusObserver(
        id: UUID,
        onFocusChange: @escaping (Bool) -> Void,
        onPrimaryInteraction: @escaping () -> Void
    ) {
        focusObservers[id] = onFocusChange
        primaryInteractionObservers[id] = onPrimaryInteraction
    }

    public func unregisterPaneFocusObserver(id: UUID) {
        focusObservers.removeValue(forKey: id)
        primaryInteractionObservers.removeValue(forKey: id)
        closeRequestObservers.removeValue(forKey: id)
        surfaceCloseObservers.removeValue(forKey: id)
    }

    public func registerPaneCloseRequestObserver(
        id: UUID,
        onCloseRequest: @escaping () -> Void
    ) {
        closeRequestObservers[id] = onCloseRequest
    }

    public func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool) -> Void
    ) {
        surfaceCloseObservers[id] = onSurfaceClosed
    }

    private func notifyPrimaryInteraction() {
        onPrimaryInteraction?()
        for observer in primaryInteractionObservers.values {
            observer()
        }
    }

    private func notifyCloseRequest() {
        onCloseRequest?()
        for observer in closeRequestObservers.values {
            observer()
        }
    }

    private func closeWithOptionalConfirmation() {
        guard shouldConfirmClose?() == true,
              hasRunningChildProcess,
              let window else {
            notifyCloseRequest()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this terminal pane?"
        alert.informativeText =
            "A process is still running."
                + " Use Ctrl-D to close without confirmation."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.notifyCloseRequest()
            }
        }
    }

    private var hasRunningChildProcess: Bool {
        if let hasRunningChildProcessOverride {
            return hasRunningChildProcessOverride()
        }
        guard let shellPID = childProcessID else {
            return false
        }
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, shellPID]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        let count = size / MemoryLayout<kinfo_proc>.size
        return count > 1
    }

    private func installAppearanceObserver() {
        appearanceObserver = observe(
            \.effectiveAppearance,
            options: [.new, .initial]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.synchronizeColorScheme()
            }
        }
    }

    // MARK: - Notifications

    @objc private func onUpdateRendererHealth(
        notification: Notification
    ) {
        guard let healthAny = notification.userInfo?["health"] else {
            return
        }
        guard let health = healthAny as? ghostty_action_renderer_health_e
        else { return }
        DispatchQueue.main.async { [weak self] in
            self?.healthy = health == GHOSTTY_RENDERER_HEALTH_HEALTHY
        }
    }

    @objc private func windowDidChangeScreen(
        notification: Notification
    ) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow,
              window == object else { return }
        guard let screen = window.screen else { return }
        guard let surface else { return }

        let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? UInt32 ?? 0
        ghostty_surface_set_display_id(surface, displayID)
        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }

    @objc private func windowDidBecomeKey(
        notification: Notification
    ) {
        guard !suppressAutoFocus,
              let window,
              let object = notification.object as? NSWindow,
              window == object else { return }
        if isCompetingFirstResponder(window.firstResponder) {
            return
        }
        ensureFirstResponder()
    }

    @objc private func windowDidResignKey(
        notification: Notification
    ) {
        guard let window,
              let object = notification.object as? NSWindow,
              window == object else { return }
        focusDidChange(false)
    }

    @objc private func windowDidChangeOcclusionState(
        notification: Notification
    ) {
        guard let window,
              let object = notification.object as? NSWindow,
              window == object else { return }
        syncOcclusionState()
    }

    private func syncOcclusionState() {
        guard let window else { return }
        let visible = Self.resolvedOcclusionVisibility(for: window)
        setSurfaceOcclusion(visible)
    }

    private func syncInitialOcclusionState(
        for window: NSWindow
    ) {
        let initialVisible = window.isVisible
            || window.isKeyWindow
            || window.occlusionState.contains(.visible)
        if initialVisible {
            setSurfaceOcclusion(true)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let currentWindow = self.window,
                  currentWindow === window else { return }
            let settledVisible = currentWindow.isVisible
                || currentWindow.isKeyWindow
                || currentWindow.occlusionState.contains(.visible)
            if settledVisible {
                setSurfaceOcclusion(true)
                return
            }
            syncOcclusionState()
        }
    }

    private func setSurfaceOcclusion(_ visible: Bool) {
        guard let surface else { return }
        Self.occlusionSetter(surface, visible)
    }

    static func resolvedOcclusionVisibility(
        for window: NSWindow
    ) -> Bool {
        let occlusionState = window.occlusionState
        if occlusionState.contains(.visible) {
            return true
        }
        if occlusionState.isEmpty {
            return window.isVisible || window.isKeyWindow
        }
        return false
    }

    // MARK: - Local Event Handling

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            return localEventKeyDown(event)
        case .keyUp:
            return localEventKeyUp(event)
        case .leftMouseDown:
            return localEventLeftMouseDown(event)
        default:
            return event
        }
    }

    private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
        if consumedPaneSplitKeyCodes.remove(event.keyCode) != nil {
            return nil
        }
        let wasConsumedCommandChord = consumedCommandKeyCodes
            .contains(event.keyCode)
        guard event.modifierFlags.contains(.command)
            || wasConsumedCommandChord else { return event }
        guard hasEffectiveKeyboardFocus else {
            if wasConsumedCommandChord {
                consumedCommandKeyCodes.remove(event.keyCode)
            }
            return event
        }
        if paneSplitShortcut(for: event) != nil {
            return nil
        }
        if isPaneCloseShortcut(event),
           hasPaneCloseHandler {
            return nil
        }
        if isReservedApplicationShortcut(event) {
            return event
        }
        guard wasConsumedCommandChord || hasLibghosttyKeyBinding(for: event) else {
            return event
        }
        consumedCommandKeyCodes.remove(event.keyCode)
        keyUp(with: event)
        return nil
    }

    private func localEventKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.modifierFlags.contains(.command) else { return event }
        guard hasEffectiveKeyboardFocus else { return event }
        if handlePaneSplitShortcut(event) {
            return nil
        }
        if isPaneCloseShortcut(event),
           hasPaneCloseHandler {
            closeWithOptionalConfirmation()
            return nil
        }
        if isReservedApplicationShortcut(event) {
            return event
        }
        if let zoomCommand = fontZoomCommand(for: event),
           hasLibghosttyKeyBinding(for: event),
           fontZoomShortcutHandler?(zoomCommand) == true {
            return nil
        }
        guard hasLibghosttyKeyBinding(for: event) else { return event }
        consumedCommandKeyCodes.insert(event.keyCode)
        keyDown(with: event)
        return nil
    }

    private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
        guard !isParkedForPreview else { return event }
        guard let window,
              event.window != nil,
              window == event.window else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }
        notifyPrimaryInteraction()
        if window.firstResponder === self, focused {
            return event
        }

        ensureFirstResponder()
        return event
    }

    // MARK: - NSView Overrides

    override public func becomeFirstResponder() -> Bool {
        guard !isParkedForPreview else { return false }
        let result = super.becomeFirstResponder()
        if result, window?.isKeyWindow == true {
            focusDidChange(true)
        }
        return result
    }

    override public func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            focusDidChange(false)
        }
        return result
    }

    override public func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }

        guard !isParkedForPreview else { return }

        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        ))
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()

        // Reparenting a parked view can briefly expose a degenerate AppKit
        // transform. Publishing a scale derived from that transition can make
        // libghostty's DPI conversion abort. A parked preview retains its last
        // terminal scale and pixel size until it becomes interactive again.
        guard !isParkedForPreview,
              let window,
              let surface
        else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        let logicalSize = bounds.size
        guard logicalSize.width.isFinite,
              logicalSize.height.isFinite,
              logicalSize.width > 0,
              logicalSize.height > 0
        else { return }
        let fbFrame = convertToBacking(NSRect(
            origin: .zero,
            size: logicalSize
        ))
        guard let pixelSize = SurfacePixelSize(fbFrame.size) else { return }
        let contentScale = window.backingScaleFactor
        guard contentScale.isFinite,
              contentScale >= 1,
              contentScale <= 8
        else { return }
        Self.contentScaleSetter(surface, contentScale, contentScale)
        applySurfaceSize(
            width: pixelSize.width,
            height: pixelSize.height
        )
    }

    override public func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        isDeferringLiveResize = true
    }

    override public func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        isDeferringLiveResize = false
        if !isDeferringSurfaceResize {
            flushPendingSurfaceResize()
        }
    }

    // MARK: - Mouse Events

    override public func mouseDown(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleMouseDown(event)
    }

    override public func mouseUp(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleMouseUp(event)
    }

    override public func otherMouseDown(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleOtherMouseDown(event)
    }

    override public func otherMouseUp(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleOtherMouseUp(event)
    }

    override public func rightMouseDown(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        if !mouseEventHandler.handleRightMouseDown(event) {
            super.rightMouseDown(with: event)
        }
    }

    override public func rightMouseUp(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        if !mouseEventHandler.handleRightMouseUp(event) {
            super.rightMouseUp(with: event)
        }
    }

    override public func mouseEntered(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        super.mouseEntered(with: event)
        mouseEventHandler.handleMouseEntered(event)
    }

    override public func mouseExited(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleMouseExited(event)
    }

    override public func mouseMoved(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleMouseMoved(event)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleMouseDragged(event)
    }

    override public func rightMouseDragged(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleRightMouseDragged(event)
    }

    override public func otherMouseDragged(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleOtherMouseDragged(event)
    }

    override public func scrollWheel(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handleScrollWheel(event)
    }

    override public func pressureChange(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        mouseEventHandler.handlePressureChange(event)
    }

    // MARK: - Keyboard Events

    override public func keyDown(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        if !hasEffectiveKeyboardFocus,
           !isCompetingFirstResponder(window?.firstResponder) {
            ensureFirstResponder()
        }

        guard let surface else {
            interpretTranslatedKeyEvents([event])
            return
        }

        let translationModsLibghostty = ghostty_surface_key_translation_mods(
            surface,
            TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        )
        let translationModsNS = ghosttyModsToNSFlags(translationModsLibghostty)

        var translationMods = event.modifierFlags
        for flag: NSEvent.ModifierFlags in [.shift, .control, .option, .command] {
            if translationModsNS.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(
                    byApplyingModifiers: translationMods
                ) ?? "",
                charactersIgnoringModifiers:
                event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat
            ? GHOSTTY_ACTION_REPEAT
            : GHOSTTY_ACTION_PRESS

        lastPerformKeyEvent = nil

        textInputHandler.keyTextAccumulator = []
        defer { textInputHandler.keyTextAccumulator = nil }

        let markedTextBefore = textInputHandler.markedText.length > 0

        interpretTranslatedKeyEvents([translationEvent])

        syncPreedit(clearIfNeeded: markedTextBefore)

        if let list = textInputHandler.keyTextAccumulator, !list.isEmpty {
            for text in list {
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: text,
                    // AppKit's committed payload is authoritative. A Return
                    // can commit an IME candidate, but its physical CR must
                    // not replace the accumulated text in the pane encoder.
                    includePhysicalEventCharacters: false
                )
            }
        } else {
            _ = keyAction(
                action,
                event: event,
                translationEvent: translationEvent,
                text: TerminalInputHelpers.ghosttyCharacters(
                    from: translationEvent
                ),
                composing: textInputHandler.markedText.length > 0
                    || markedTextBefore
            )
        }
    }

    override public func keyUp(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override public func performKeyEquivalent(
        with event: NSEvent
    ) -> Bool {
        guard !isParkedForPreview else { return false }
        guard event.type == .keyDown else { return false }
        if !hasEffectiveKeyboardFocus,
           !isCompetingFirstResponder(window?.firstResponder) {
            ensureFirstResponder()
        }
        guard hasEffectiveKeyboardFocus else { return false }

        if handlePaneSplitShortcut(event) {
            return true
        }

        if isPaneCloseShortcut(event),
           hasPaneCloseHandler {
            closeWithOptionalConfirmation()
            return true
        }

        if isReservedApplicationShortcut(event) {
            lastPerformKeyEvent = nil
            return false
        }

        if let zoomCommand = fontZoomCommand(for: event),
           hasLibghosttyKeyBinding(for: event),
           fontZoomShortcutHandler?(zoomCommand) == true {
            lastPerformKeyEvent = nil
            return true
        }

        if hasLibghosttyKeyBinding(for: event) {
            if event.modifierFlags.contains(.command) {
                consumedCommandKeyCodes.insert(event.keyCode)
            }
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else {
                return false
            }
            equivalent = "\r"

        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(
                      with: [.shift, .command, .option]
                  ) else { return false }
            equivalent = "_"

        default:
            if event.timestamp == 0 {
                return false
            }

            if event.modifierFlags.contains(.shift),
               event.modifierFlags.contains(.command) {
                return false
            }

            if !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers:
            event.charactersIgnoringModifiers ?? equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
        }
        return true
    }

    override public func flagsChanged(with event: NSEvent) {
        guard !isParkedForPreview else { return }
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        defer {
            if mod == GHOSTTY_MODS_SUPER.rawValue {
                mouseEventHandler.handleModifierFlagsChanged(event)
            }
        }

        if hasMarkedText() {
            return
        }

        let mods = TerminalInputHelpers.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let sidePressed: Bool
            switch event.keyCode {
            case 0x3C:
                sidePressed = event.modifierFlags.rawValue
                    & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E:
                sidePressed = event.modifierFlags.rawValue
                    & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D:
                sidePressed = event.modifierFlags.rawValue
                    & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36:
                sidePressed = event.modifierFlags.rawValue
                    & UInt(NX_DEVICERCMDKEYMASK) != 0
            default:
                sidePressed = true
            }
            if sidePressed {
                action = GHOSTTY_ACTION_PRESS
            }
        }

        _ = keyAction(action, event: event)
    }

    // MARK: - Key Helpers

    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false,
        includePhysicalEventCharacters: Bool = true
    ) -> Bool {
        guard let surface else { return false }

        // Diverges from fantastty: fantastty's keyAction builds the C key
        // event first and threads pane routing through the `withCString`
        // closure that supplies `key_ev.text` (its dual with-text/without-text
        // branches exist to keep that pointer's lifetime scoped correctly).
        // Ghosthub's keyAction never touches the C key event when
        // pane-routed — it dispatches to `ghostty_surface_key` asynchronously
        // via `PendingLibghosttyKeyInput` below, so routing can be decided
        // entirely up front from `event`/`text` alone.
        if let sink = tmuxPaneInputSink {
            // AppKit sends physical key events while an IME/dead key is still
            // building marked text, then delivers the committed text through
            // insertText. The local libghostty core understands `composing`, but
            // the pane encoder only deals in final terminal bytes. Consume
            // the in-progress event here so the eventual insertText payload
            // is the only text forwarded to tmux.
            if composing {
                return true
            }
            // Diverges from fantastty: fantastty's Cmd+V reaches an
            // `@IBAction func paste(_:)` override because its
            // performKeyEquivalent detects "consumed" bindings and
            // re-dispatches through NSApp.mainMenu.performKeyEquivalent(with:)
            // first, letting the menu's nil-targeted Paste item find that
            // selector on the first responder before the event reaches
            // keyDown. Ghosthub's local NSEvent monitor (`localEventKeyDown`)
            // consumes Cmd+V directly and calls `keyDown(with:)` itself
            // whenever the shortcut has a libghostty key binding (paste is
            // bound by default), so `performKeyEquivalent` never runs for
            // it — this chokepoint must live here instead, ahead of the
            // "Cmd-held stays local" rule below, or paste silently goes to
            // the local core even when a pane sink is attached.
            if action != GHOSTTY_ACTION_RELEASE, isPasteShortcut(event) {
                if let data = Self.explicitPasteData(
                    from: TerminalPasteboardAccess.current
                ) {
                    if let pasteSink = tmuxPanePasteSink {
                        pasteSink(data)
                    } else {
                        sink(data)
                    }
                    return true
                }
                // No pasteboard string content to route: fall through to
                // local paste handling below — mirrors fantastty's
                // pasteViaTmux(), which only swallows the shortcut when it
                // actually has something to send.
            } else if AttachedTmuxInputRouter.shouldHandleLocally(bindingFlags: nil, event: event) {
                // Cmd-held chords stay local (app shortcuts, copy, etc.).
            } else {
                let eventCharacters = includePhysicalEventCharacters
                    ? AttachedTmuxInputEncoder.eventCharacters(for: event)
                    : nil
                if let data = AttachedTmuxInputEncoder.inputData(
                    isRelease: action == GHOSTTY_ACTION_RELEASE,
                    text: text,
                    eventCharacters: eventCharacters,
                    keyCode: event.keyCode,
                    modifierFlags: event.modifierFlags,
                    optionWasConsumedForMeta:
                    event.modifierFlags.contains(.option)
                        && translationEvent?.modifierFlags.contains(.option) == false
                ) {
                    sink(data)
                    return true
                }
                if action != GHOSTTY_ACTION_RELEASE,
                   let data = AttachedTmuxInputEncoder.escapeSequence(
                       keyCode: event.keyCode,
                       eventCharacters: eventCharacters,
                       modifierFlags: event.modifierFlags,
                       applicationCursorKeys:
                       tmuxTerminalModeTracker.applicationCursorKeys
                   ) {
                    sink(data)
                    return true
                }
                // Unencodable routed keys are swallowed: forwarding them to
                // the local core would deadlock its input queue (fantastty
                // invariant).
                return true
            }
        }

        var keyEvent = TerminalInputHelpers.ghosttyKeyEvent(
            from: event,
            action: action,
            translationMods: translationEvent?.modifierFlags
        )
        keyEvent.composing = composing

        // Dispatch key events off the main thread to prevent
        // deadlocking when libghostty's internal message queue is
        // full due to heavy output (e.g. cat /dev/urandom).
        // The main thread must stay free to drain libghostty's
        // response queue; blocking here creates circular
        // backpressure that beachballs the app.
        let input = PendingLibghosttyKeyInput(
            surfaceAddress: UInt(bitPattern: surface),
            keyEvent: keyEvent,
            text: text
        )
        keyInputQueue.async {
            input.send()
        }

        return true
    }

    private func ghosttyModsToNSFlags(
        _ mods: ghostty_input_mods_e
    ) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 {
            flags.insert(.shift)
        }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 {
            flags.insert(.control)
        }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 {
            flags.insert(.option)
        }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 {
            flags.insert(.command)
        }
        return flags
    }

    /// Returns true when the responder is a meaningful interactive
    /// control that should keep focus (e.g., text fields, table
    /// views, sidebar controls). Returns false for container or
    /// host views that report acceptsFirstResponder but are not
    /// controls the user intentionally focused.
    private func isCompetingFirstResponder(
        _ responder: NSResponder?
    ) -> Bool {
        guard let view = responder as? NSView else {
            return false
        }
        if view === self {
            return false
        }
        return view is NSControl
            || view is NSText
            || view is NSCollectionView
            || view is TerminalSurfaceView
    }

    func ensureFirstResponder() {
        guard !isParkedForPreview else { return }
        guard let window, window.isKeyWindow else { return }
        if window.firstResponder === self {
            if !focused {
                focusDidChange(true)
            }
            return
        }

        window.makeFirstResponder(self)
        if window.firstResponder === self, !focused {
            focusDidChange(true)
        }
    }

    private func interpretTranslatedKeyEvents(_ events: [NSEvent]) {
        if let keyEventInterpreter {
            keyEventInterpreter(events)
            return
        }

        interpretKeyEvents(events)
    }

    func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if textInputHandler.markedText.length > 0 {
            let str = textInputHandler.markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                textInputHandler.markedText.string.withCString { ptr in
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func hasLibghosttyKeyBinding(for event: NSEvent) -> Bool {
        guard let surface else { return false }

        var ghosttyEvent = TerminalInputHelpers.ghosttyKeyEvent(
            from: event,
            action: GHOSTTY_ACTION_PRESS
        )
        var bindingFlags = ghostty_binding_flags_e(rawValue: 0)
        return (event.characters ?? "").withCString { ptr in
            ghosttyEvent.text = ptr
            return ghostty_surface_key_is_binding(
                surface,
                ghosttyEvent,
                &bindingFlags
            )
        }
    }

    /// Matches the standard Cmd+V paste shortcut. See the divergence note in
    /// `keyAction` for why this substitutes for fantastty's menu-routed
    /// `paste(_:)` override.
    private func isPasteShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Require Cmd and no other chord-changing modifier, but don't
        // compare flags for exact equality against `.command` -- that
        // breaks when Caps Lock is active, since `.capsLock` (and
        // `.numericPad`/`.function`) are also part of
        // deviceIndependentFlagsMask and would make the comparison fail.
        return flags.contains(.command)
            && !flags.contains(.shift)
            && !flags.contains(.option)
            && !flags.contains(.control)
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    func requestClipboardConfirmation(
        contents: String,
        request: ghostty_clipboard_request_e,
        completion: @escaping (Bool) -> Void
    ) {
        guard !isClipboardConfirmationPending else {
            completion(false)
            return
        }
        isClipboardConfirmationPending = true
        let finish: (Bool) -> Void = { [self] approved in
            isClipboardConfirmationPending = false
            completion(approved)
        }

        if let presenter = Self.clipboardConfirmationPresenter {
            presenter(self, contents, request, finish)
            return
        }

        let isPaste = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
        let alert = NSAlert()
        alert.messageText = isPaste
            ? "Paste potentially unsafe text?"
            : "Allow terminal clipboard access?"
        alert.informativeText = isPaste
            ? "This text contains line breaks or control sequences and may execute commands immediately."
            : "A terminal process requested the contents of the Mac clipboard."
        alert.alertStyle = .warning
        alert.addButton(withTitle: isPaste ? "Paste" : "Allow")
        alert.addButton(withTitle: isPaste ? "Cancel" : "Deny")

        let handleResponse: (NSApplication.ModalResponse) -> Void = {
            response in
            finish(response == .alertFirstButtonReturn)
        }
        if let window {
            alert.beginSheetModal(
                for: window,
                completionHandler: handleResponse
            )
        } else {
            handleResponse(alert.runModal())
        }
    }

    /// Diverges from fantastty: fantastty reads the pasteboard through its
    /// own `NSPasteboard.getOpinionatedStringContents()` extension (not
    /// ported here). This uses the standard `.string` pasteboard type.
    static func explicitPasteData(
        from pasteboard: any TerminalPasteboard
    ) -> Data? {
        guard let string = pasteboard.string(forType: .string),
              !string.isEmpty
        else { return nil }
        return Data(string.utf8)
    }
}

// MARK: - TerminalMouseEventDelegate

extension TerminalSurfaceView: TerminalMouseEventDelegate {}

// MARK: - TerminalTextInputDelegate

extension TerminalSurfaceView: TerminalTextInputDelegate {}

// MARK: - NSTextInputClient

extension TerminalSurfaceView: @preconcurrency NSTextInputClient {
    public func hasMarkedText() -> Bool {
        textInputHandler.hasMarkedText()
    }

    public func markedRange() -> NSRange {
        textInputHandler.markedRange()
    }

    public func selectedRange() -> NSRange {
        textInputHandler.selectedRange()
    }

    public func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        textInputHandler.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    public func unmarkText() {
        textInputHandler.unmarkText()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        textInputHandler.validAttributesForMarkedText()
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        textInputHandler.attributedSubstring(
            forProposedRange: range, actualRange: actualRange
        )
    }

    public func characterIndex(for point: NSPoint) -> Int {
        textInputHandler.characterIndex(for: point)
    }

    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        textInputHandler.firstRect(
            forCharacterRange: range, actualRange: actualRange
        )
    }

    public func insertText(
        _ string: Any,
        replacementRange: NSRange
    ) {
        textInputHandler.insertText(
            string, replacementRange: replacementRange
        )
    }

    override public func doCommand(by selector: Selector) {
        textInputHandler.doCommand(by: selector)
    }
}

extension TerminalSurfaceView {
    var hasPaneCloseHandler: Bool {
        onCloseRequest != nil || !closeRequestObservers.isEmpty
    }

    var consumedCommandKeyCodesForTesting: Set<UInt16> {
        consumedCommandKeyCodes
    }

    @discardableResult
    func processLocalEventForTesting(_ event: NSEvent) -> NSEvent? {
        localEventHandler(event)
    }

    func insertTextForTesting(
        _ string: Any,
        modifierFlags: NSEvent.ModifierFlags = []
    ) {
        textInputHandler.insertText(
            string,
            replacementRange: NSRange(location: NSNotFound, length: 0),
            modifierFlags: modifierFlags
        )
    }

    @discardableResult
    func handleFontZoomShortcutForTesting(_ event: NSEvent) -> Bool {
        guard let command = fontZoomCommand(for: event) else {
            return false
        }
        return fontZoomShortcutHandler?(command) == true
    }

    @discardableResult
    func handlePaneSplitShortcutForTesting(_ event: NSEvent) -> Bool {
        handlePaneSplitShortcut(event)
    }

    func markConsumedCommandKeyCodeForTesting(_ keyCode: UInt16) {
        consumedCommandKeyCodes.insert(keyCode)
    }

    func notifyCloseRequestForTesting() {
        notifyCloseRequest()
    }
}

extension TerminalSurfaceView {
    /// Pure reservation logic, extracted for testability. Forwards to the
    /// shared `TerminalApplicationShortcut` so the real and unavailable terminal
    /// targets reserve identical shortcuts.
    nonisolated static func isReservedApplicationShortcut(
        flags: NSEvent.ModifierFlags,
        chars: String?,
        keyCode: UInt16,
        hasPaneCloseHandler: Bool,
        shortcuts: ResolvedApplicationShortcuts =
            ApplicationShortcutCatalog.compiledDefaults
    ) -> Bool {
        TerminalApplicationShortcut.isReserved(
            flags: flags,
            chars: chars,
            keyCode: keyCode,
            hasPaneCloseHandler: hasPaneCloseHandler,
            shortcuts: shortcuts
        )
    }

    package var hasEffectiveKeyboardFocus: Bool {
        guard !isParkedForPreview,
              let window, window.isKeyWindow,
              window.attachedSheet == nil
        else { return false }
        return focused || window.firstResponder === self
    }
}

private extension TerminalSurfaceView {
    func paneSplitShortcut(
        for event: NSEvent
    ) -> TerminalPaneSplitShortcut? {
        guard paneSplitShortcutHandler != nil else { return nil }
        guard let binding = ApplicationKeyBinding(
            appKitModifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        ), let action = (applicationShortcutsProvider?()
            ?? ApplicationShortcutCatalog.compiledDefaults).action(
            for: binding
        )
        else { return nil }
        return TerminalPaneSplitShortcut(
            applicationShortcutAction: action
        )
    }

    func handlePaneSplitShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = paneSplitShortcut(for: event) else {
            return false
        }
        consumedPaneSplitKeyCodes.insert(event.keyCode)
        if !event.isARepeat {
            paneSplitShortcutHandler?(shortcut)
        }
        return true
    }

    func fontZoomCommand(
        for event: NSEvent
    ) -> TerminalFontZoomCommand? {
        let flags = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        let chars = event.charactersIgnoringModifiers?.lowercased()
        guard flags.contains(.command),
              !flags.contains(.control),
              !flags.contains(.option)
        else {
            return nil
        }

        switch chars {
        case "=", "+":
            return .increase
        case "-":
            return .decrease
        case "0":
            return .reset
        default:
            return nil
        }
    }

    func isPaneCloseShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        return flags == .command
            && event.charactersIgnoringModifiers == "w"
    }

    func isReservedApplicationShortcut(_ event: NSEvent) -> Bool {
        Self.isReservedApplicationShortcut(
            flags: event.modifierFlags
                .intersection(.deviceIndependentFlagsMask),
            chars: event.charactersIgnoringModifiers?.lowercased(),
            keyCode: event.keyCode,
            hasPaneCloseHandler: hasPaneCloseHandler,
            shortcuts: applicationShortcutsProvider?()
                ?? ApplicationShortcutCatalog.compiledDefaults
        )
    }
}

// MARK: - Error

enum TerminalSurfaceError: LocalizedError {
    case surfaceCreationFailed(activeDisplayCount: Int)
    case surfaceClosed(processAlive: Bool)

    var errorDescription: String? {
        switch self {
        case .surfaceCreationFailed:
            return "Ghosthub could not create the terminal surface."
        case let .surfaceClosed(processAlive):
            return processAlive
                ? "Surface closed while process is still running"
                : "Surface closed after process exited"
        }
    }
}
