import AppKit
import Foundation
import SwiftUI
import Combine
import GhosthubTerminalSupport
import GhosthubWorkspace

enum TerminalFontZoomCommand: Equatable, Sendable {
    case increase
    case decrease
    case reset

    func bindingAction(
        overridePoints: CGFloat?
    ) -> String {
        _ = overridePoints
        return ""
    }

    static func setFontSizeAction(
        points: CGFloat
    ) -> String {
        _ = points
        return ""
    }
}

enum TerminalSurfaceError: LocalizedError {
    case surfaceCreationFailed
    case surfaceClosed(processAlive: Bool)

    var errorDescription: String? {
        switch self {
        case .surfaceCreationFailed:
            "Terminal surface creation failed"
        case let .surfaceClosed(processAlive):
            processAlive
                ? "Terminal surface closed (process still running)"
                : "Terminal surface closed"
        }
    }
}

public struct TerminalSurfaceConfiguration: Equatable, Sendable {
    public var workingDirectory: String?
    public var command: String?
    public var environmentVariables: [String: String] = [:]
    public var initialInput: String?
    public var fontSize: CGFloat?
    public var waitAfterCommand: Bool = false

    public init(
        workingDirectory: String? = nil,
        command: String? = nil,
        environmentVariables: [String: String] = [:],
        initialInput: String? = nil,
        fontSize: CGFloat? = nil,
        waitAfterCommand: Bool = false
    ) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.environmentVariables = environmentVariables
        self.initialInput = initialInput
        self.fontSize = fontSize
        self.waitAfterCommand = waitAfterCommand
    }
}

@MainActor
public final class TerminalSurfaceView: ObservableObject {
    @Published public internal(set) var title: String = ""
    @Published public private(set) var focused: Bool = false
    @Published public var error: Error?
    public internal(set) var childExitCode: UInt32?

    public var suppressAutoFocus: Bool = false
    public var onFocusChange: ((Bool) -> Void)?
    public var onPrimaryInteraction: (() -> Void)?
    public var onCloseRequest: (() -> Void)?
    public var shouldConfirmClose: (() -> Bool)?
    @Published public var tmuxSplitErrorMessage: String?
    public var tmuxSplitShortcutHandler: ((TerminalTmuxSplitShortcut) -> Void)?
    package var hasEffectiveKeyboardFocus = false
    public var hasRunningChildProcessOverride: (() -> Bool)?
    public var onSurfaceClosed: ((Bool) -> Void)?
    /// Mirrors `TerminalSurfaceView.tmuxPaneInputSink` so tmux control-mode
    /// pane wiring compiles against the unbootstrapped stub target.
    public var tmuxPaneInputSink: ((Data) -> Void)?
    /// Mirrors `TerminalSurfaceView.tmuxPanePasteSink`.
    public var tmuxPanePasteSink: ((Data) -> Void)?
    /// Mirrors `TerminalSurfaceView.onChildWrite`.
    public var onChildWrite: ((Data) -> Void)?
    /// Mirrors `TerminalSurfaceView.onGridSizeChanged`.
    public var onGridSizeChanged: ((Int, Int) -> Void)?
    package var onSurfaceDestroyed: (@MainActor @Sendable (UInt) -> Void)?
    /// Mirrors clipboard-read isolation for remote surfaces.
    public var blocksClipboardReads: Bool = false
    var fontZoomShortcutHandler: ((TerminalFontZoomCommand) -> Bool)?

    public init(
        app: AnyObject? = nil,
        configuration: TerminalSurfaceConfiguration,
        keyEventInterpreter: (([Any]) -> Void)? = nil,
        textInputObserver: ((String) -> Void)? = nil,
        commandObserver: ((Selector) -> Void)? = nil
    ) {
        _ = app
        _ = configuration
        _ = keyEventInterpreter
        _ = textInputObserver
        _ = commandObserver
    }

    public var childProcessID: Int32? { nil }
    public var pwd: String?
    public var window: NSWindow? { nil }
    package var surfaceIdentity: UInt? { nil }
    var currentFontSizePoints: CGFloat? { nil }

    public func sendProgrammaticInput(_ string: String) {
        _ = string
    }

    public func sendProgrammaticReturn() {}

    /// Mirrors `TerminalSurfaceView.injectOutput(_:)`. Always fails: there is
    /// no real surface backing this stub to inject bytes into.
    public func injectOutput(_ data: Data) -> Bool {
        _ = data
        return false
    }

    public func setTmuxApplicationCursorKeys(_ enabled: Bool) {
        _ = enabled
    }
    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        _ = action
        return true
    }

    public func requestKeyboardFocus() {}
    public func focusDidChange(_ newFocused: Bool) {
        focused = newFocused
        onFocusChange?(newFocused)
    }
    public func sizeDidChange(_ size: CGSize) {
        _ = size
    }
    func setPresentationResizeDeferred(_ deferred: Bool) {
        _ = deferred
    }
    public func registerPaneFocusObserver(
        id: UUID,
        onFocusChange: @escaping (Bool) -> Void,
        onPrimaryInteraction: @escaping () -> Void
    ) {
        _ = id
        _ = onFocusChange
        _ = onPrimaryInteraction
    }
    public func unregisterPaneFocusObserver(id: UUID) {
        _ = id
    }
    public func registerPaneCloseRequestObserver(
        id: UUID,
        onCloseRequest: @escaping () -> Void
    ) {
        _ = id
        _ = onCloseRequest
    }
    public func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool) -> Void
    ) {
        _ = id
        _ = onSurfaceClosed
    }
}

extension TerminalSurfaceView {
    /// Mirrors the real terminal view's reservation entry point by forwarding
    /// to the shared `TerminalApplicationShortcut`, so shortcut-reservation
    /// tests compile and pass against the unavailable (unbootstrapped) target.
    nonisolated static func isReservedApplicationShortcut(
        flags: NSEvent.ModifierFlags,
        chars: String?,
        keyCode: UInt16,
        hasPaneCloseHandler: Bool
    ) -> Bool {
        TerminalApplicationShortcut.isReserved(
            flags: flags,
            chars: chars,
            keyCode: keyCode,
            hasPaneCloseHandler: hasPaneCloseHandler
        )
    }
}

@MainActor
public final class TerminalSurfaceCoordinator: ObservableObject {
    private let runtime: LibghosttyRuntime
    private var surfaces: [(key: SurfaceKey, view: TerminalSurfaceView)] = []
    public var onSurfaceCreated: ((SurfaceKey, TerminalSurfaceView) -> Void)?

    public init(runtime: LibghosttyRuntime) {
        self.runtime = runtime
    }

    public func surface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> TerminalSurfaceView? {
        if let existing = surfaces.first(where: { $0.key == key }) {
            return existing.view
        }
        let view = TerminalSurfaceView(
            configuration: configuration
        )
        surfaces.append((key: key, view: view))
        onSurfaceCreated?(key, view)
        return view
    }

    public func surfaceKey(
        for surfaceView: TerminalSurfaceView
    ) -> SurfaceKey? {
        surfaces.first { $0.view === surfaceView }?.key
    }

    public func surfaceKey(
        forSurfaceIdentity identity: UInt
    ) -> SurfaceKey? {
        _ = identity
        return nil
    }

    public func containsSurface(for key: SurfaceKey) -> Bool {
        surfaces.contains { $0.key == key }
    }

    public func surfaceIfPresent(
        for key: SurfaceKey
    ) -> TerminalSurfaceView? {
        surfaces.first { $0.key == key }?.view
    }

    public func surfaceEntries() -> [(key: SurfaceKey, view: TerminalSurfaceView)] {
        surfaces
    }

    public func removeSurface(for key: SurfaceKey) {
        surfaces.removeAll { $0.key == key }
    }
    public func removeWorktreeSurfaces(worktreeID: UUID) {
        surfaces.removeAll { $0.key.worktreeID == worktreeID }
    }
    public func removeConsoleSurfaces(hostID: UUID) {
        surfaces.removeAll {
            $0.key.hostID == hostID && $0.key.target == .console
        }
    }
    public func removeAll() {
        surfaces.removeAll()
    }

    func applyFontZoom(_ command: TerminalFontZoomCommand) {
        _ = command
    }
}

struct SurfaceResizeState: Equatable {
    struct Size: Equatable {
        let width: UInt32
        let height: UInt32
    }

    private(set) var lastPixelSize: Size?
    private(set) var pendingPixelSize: Size?

    mutating func needsResize(
        width: UInt32, height: UInt32
    ) -> Bool {
        let size = Size(width: width, height: height)
        return pendingPixelSize != size || lastPixelSize != size
    }

    mutating func setPending(width: UInt32, height: UInt32) {
        pendingPixelSize = Size(width: width, height: height)
    }

    mutating func consumePending() -> Size? {
        defer { pendingPixelSize = nil }
        return pendingPixelSize
    }

    mutating func apply(
        width: UInt32, height: UInt32
    ) {
        pendingPixelSize = nil
        lastPixelSize = Size(width: width, height: height)
    }
}

public struct TerminalSurfaceSwiftUIView: View {
    public init(
        surfaceView: TerminalSurfaceView,
        defersSurfaceResize: Bool = false
    ) {
        _ = surfaceView
        _ = defersSurfaceResize
    }

    public var body: some View {
        Text("Terminal unavailable — run make bootstrap-libghostty")
            .foregroundStyle(.secondary)
    }
}

public struct TerminalSurfaceRepresentable: NSViewRepresentable {
    public let surfaceView: TerminalSurfaceView
    public let defersSurfaceResize: Bool

    public init(
        surfaceView: TerminalSurfaceView,
        defersSurfaceResize: Bool = false
    ) {
        self.surfaceView = surfaceView
        self.defersSurfaceResize = defersSurfaceResize
    }

    public func makeNSView(context _: Context) -> NSView {
        _ = surfaceView
        return NSHostingView(
            rootView: Text(
                "Terminal unavailable — run make bootstrap-libghostty"
            )
            .foregroundStyle(.secondary)
        )
    }

    public func updateNSView(
        _: NSView, context _: Context
    ) {}
}
