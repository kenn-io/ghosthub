import AppKit
import Foundation
import GhosthubBackendTerminal
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTransport
import GhosthubWorkspace

/// Shows one Rex window: follows its layout through `kwt rex control`,
/// attaches each pane with `kwt rex attach`, and sends the user's layout
/// changes to Rex. Rex owns the layout; a change shows once Rex reports it.
///
/// It also shows a Herdr desktop tab, through `HerdrTabChannel`, with each
/// pane attached by `herdr-core attach`. The Herdr desktop app owns that
/// layout, so it cannot change here; focus and zoom stay in Ghosthub.
@MainActor
final class RexWindowPresentation {
    /// The window. Its address is the Rex window ID, or the Herdr tab's
    /// `tab:` address.
    let selection: WorkspaceBackendTerminalSelection
    let container: TerminalSplitContainerView
    private(set) var tree: TerminalSplitTree?
    private(set) var paneHandles: [String: BorrowedBackendTerminalHandle] = [:]
    private(set) var isStopped = false

    /// The window or its session is gone.
    var onWindowClosed: (() -> Void)?
    /// kwt rex control stopped without the session ending.
    var onChannelFailed: ((String) -> Void)?
    /// The user asked to close a pane. The caller confirms, then calls
    /// `closePane`.
    var onCloseRequested: ((String) -> Void)?
    /// The panes, names, or focus changed.
    var onChange: (() -> Void)?

    private let host: CommandHost
    private let validated: SSHConnectionArgumentsSnapshot
    private let channel: any RexControlChannelling
    private let coordinator: NativeBackendTerminalCoordinator
    /// The SSH session that carries `kwt rex control`, if the host is remote.
    private let sshConnection: KwtSSHConnection?
    private var sessionID: String?
    private var paneNames: [String: String] = [:]
    private var windowLabel = ""
    private var sessionLabel = ""
    private var paneDirectories: [String: String] = [:]
    private var paneStates: [String: ConnectionState] = [:]
    private var paneContents: [String: TerminalSurfaceView] = [:]
    private var keyboardSuspended = false
    /// The pane the user last chose, until Rex shows the session at or
    /// after the revision its focus request produced. Views and replies
    /// arrive in no fixed order, so an older view must not move keyboard
    /// focus back to an earlier choice. kwt sends requests to Rex in order,
    /// so a view that includes the latest one includes them all.
    private var requestedFocus: String?
    private var focusRequestCount = 0
    private var requestedFocusRevision: Int?
    /// The revision of the last view from Rex.
    private var viewRevision: Int?
    /// Panes waiting to attach again after a lost connection.
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var reconnectAttempts: [String: Int] = [:]
    private let waitForReconnect: @MainActor (Int) async throws -> Void

    init(
        selection: WorkspaceBackendTerminalSelection,
        host: CommandHost,
        validated: SSHConnectionArgumentsSnapshot,
        channel: any RexControlChannelling,
        coordinator: NativeBackendTerminalCoordinator,
        sshConnection: KwtSSHConnection? = nil,
        container: TerminalSplitContainerView = TerminalSplitContainerView(),
        waitForReconnect: @escaping @MainActor (Int) async throws -> Void = { attempt in
            try await Task.sleep(for: .seconds(min(30, 1 << min(attempt, 5))))
        }
    ) {
        self.selection = selection
        self.host = host
        self.validated = validated
        self.channel = channel
        self.coordinator = coordinator
        self.sshConnection = sshConnection
        self.container = container
        self.waitForReconnect = waitForReconnect
        container.isLayoutEditable = selection.kind == .rex
        channel.onView = { [weak self] view in self?.show(view) }
        channel.onExit = { [weak self] exit in self?.channelExited(exit) }
        coordinator.onStateChanged = { [weak self] handle, state in
            self?.paneStateChanged(handle, state)
        }
        coordinator.onSurfaceReady = { [weak self] handle in
            self?.paneReady(handle)
        }
        container.onResizeCommitted = { [weak self] divider, ratio in
            self?.resize(divider, to: ratio)
        }
        container.onLayerBoundsCommitted = { [weak self] layerID, bounds in
            self?.moveLayer(layerID, to: bounds)
        }
        container.onPaneDropped = { [weak self] blockID, drop in
            self?.dropPane(blockID, on: drop)
        }
        container.onLayerRestored = { [weak self] layerID in
            self?.showLayer(layerID)
        }
        container.onPaneClicked = { [weak self] blockID in
            self?.paneFocused(blockID)
        }
        container.onHeaderAction = { [weak self] blockID, action in
            self?.headerAction(action, blockID: blockID)
        }
        container.onPaneReconnect = { [weak self] blockID in
            self?.reconnectPane(blockID)
        }
    }

    /// Whether the user can split, close, float, resize, or move panes.
    var isLayoutEditable: Bool { selection.kind == .rex }

    /// The pane that has, or is about to get, focus: the user's latest
    /// choice, else the one Rex reports.
    var focusedPaneID: String? { requestedFocus ?? tree?.focusedPaneID }

    /// The tree as shown, with the user's latest focus choice.
    private var shownTree: TerminalSplitTree? {
        guard var tree else { return nil }
        tree.focusedPaneID = focusedPaneID
        return tree
    }

    /// True when one of this window's panes takes the keystrokes.
    var hasKeyboardFocus: Bool {
        paneHandles.values.contains { coordinator.hasKeyboardFocus(handle: $0) }
    }

    /// The window's sidebar row as this view shows it, which can be newer
    /// than the last inventory listing.
    var row: BackendTerminalSummary? {
        guard let tree else { return nil }
        if selection.kind == .herdrCore {
            return HerdrCoreInventory.tabRow(
                address: selection.address, name: windowLabel, spaceName: sessionLabel,
                paneCount: tree.paneIDs.count
            )
        }
        return RexInventory.windowRow(
            windowID: selection.address,
            windowLabel: windowLabel,
            sessionLabel: sessionLabel,
            focusedPaneNames: [focusedPaneID.flatMap { paneNames[$0] }],
            paneCount: tree.paneIDs.count
        )
    }

    func title(ofPane blockID: String) -> String {
        paneNames[blockID] ?? blockID
    }

    // MARK: Requests

    /// Splits the focused pane, as ⌘D and ⇧⌘D do in Rex.app. The new
    /// shell starts in the anchor pane's directory.
    func split(_ direction: TerminalPaneSplitShortcut, from blockID: String? = nil) {
        guard let anchor = blockID ?? focusedPaneID else { return }
        request("session.new_split", [
            "anchor_id": anchor,
            "direction": direction == .right ? "horizontal" : "vertical",
            "side": "after",
            "focus": true,
            "layout": ["block": shell(startingBeside: anchor)],
        ])
    }

    /// A new shell block that starts in the pane's directory.
    private func shell(startingBeside blockID: String?) -> [String: any Sendable] {
        var shell: [String: any Sendable] = ["flavor": "com.superlogical.terminal.shell"]
        if let cwd = blockID.flatMap({ paneDirectories[$0] }) {
            shell["options"] = ["cwd": cwd]
        }
        return shell
    }

    /// Moves focus within this window. Rex's own focus moves act on the
    /// session's active window, which may be another one, so the target
    /// comes from this window's layout.
    @discardableResult
    func moveFocus(_ move: TerminalSplitFocusMove) -> Bool {
        guard let tree = shownTree,
              let target = TerminalSplitLayout.pane(
                  move, from: tree, in: container.bounds, metrics: container.metrics
              )
        else { return false }
        paneFocused(target)
        return true
    }

    /// Opens a shell in a new floating window, in the focused pane's
    /// directory.
    func newFloatingPane() {
        request("session.new_layer", [
            "window_id": selection.address,
            "bounds": Self.boundsValue(newFloatingBounds()),
            "focus": true,
            "layout": ["block": shell(startingBeside: focusedPaneID)],
        ])
    }

    /// Moves a tiled pane into a floating window, or a floating one back
    /// into the tiled layout, as Rex.app's Float Pane does.
    func toggleFloating(_ blockID: String? = nil) {
        guard let tree, let block = blockID ?? focusedPaneID else { return }
        if tree.floatingLayer(holding: block) == nil {
            request("session.float_block", [
                "block_id": block,
                "bounds": Self.boundsValue(newFloatingBounds()),
            ])
        } else if let anchor = tilingAnchor(for: block) {
            request("session.move_block", [
                "block_id": block,
                "anchor_block_id": anchor,
                "direction": "horizontal",
                "side": "after",
            ])
        }
    }

    /// Moves a pane dragged by its header beside the pane it was dropped
    /// on, or trades their places when dropped in that pane's middle.
    func dropPane(_ blockID: String, on drop: TerminalSplitPaneDrop) {
        let zone = drop.zone
        guard zone != .center else {
            request("session.swap_blocks", ["block_id": blockID, "other_block_id": drop.paneID])
            return
        }
        request("session.move_block", [
            "block_id": blockID,
            "anchor_block_id": drop.paneID,
            "direction": zone == .left || zone == .right ? "horizontal" : "vertical",
            "side": zone == .left || zone == .top ? "before" : "after",
        ])
    }

    /// True when the focused pane floats and Rex would let its window be
    /// minimized.
    var canMinimizeFocusedFloatingWindow: Bool {
        guard let tree, let focused = focusedPaneID else { return false }
        return TerminalSplitContainerView.actions(for: focused, in: tree).contains(.minimize)
    }

    /// Hides the floating window that holds the pane. Its panes keep
    /// running, and its capsule shows it again.
    func minimizeFloatingWindow(_ blockID: String? = nil) {
        guard let block = blockID ?? focusedPaneID,
              let layer = tree?.floatingLayer(holding: block)
        else { return }
        request("session.set_layer_state", ["layer_id": layer.id, "state": "minimized"])
    }

    func toggleZoom(_ blockID: String? = nil) {
        guard let block = blockID ?? focusedPaneID else { return }
        request("session.zoom_block", ["block_id": block])
    }

    /// Ends the pane's program. The caller has confirmed.
    func closePane(_ blockID: String) {
        request("block.close", ["block_id": blockID])
    }

    /// A pane's terminal was clicked. Its floating window comes to the
    /// front even when the pane already has focus, since another Rex app
    /// may have raised a different window.
    func panePressed(_ blockID: String) {
        raiseLayer(holding: blockID)
    }

    /// A pane took keyboard focus or its header was clicked.
    func paneFocused(_ blockID: String) {
        guard paneHandles[blockID] != nil else { return }
        raiseLayer(holding: blockID)
        guard blockID != focusedPaneID else {
            // Already chosen, but another control may hold the keyboard.
            requestKeyboardFocus()
            return
        }
        requestedFocus = blockID
        requestedFocusRevision = nil
        focusRequestCount += 1
        let serial = focusRequestCount
        render()
        requestKeyboardFocus()
        request(
            "session.focus_block", ["block_id": blockID],
            onFailure: { [weak self] in
                guard let self, focusRequestCount == serial else { return }
                updateFocus { $0.requestedFocus = nil }
            },
            onSuccess: { [weak self] revision in
                guard let self, focusRequestCount == serial else { return }
                // Rex always reports one; without it, Rex's focus is current.
                updateFocus {
                    $0.requestedFocusRevision = revision ?? 0
                    $0.settleRequestedFocus()
                }
            }
        )
    }

    private func updateFocus(_ change: (RexWindowPresentation) -> Void) {
        let previousFocus = focusedPaneID
        change(self)
        if focusedPaneID != previousFocus {
            render()
            requestKeyboardFocus()
        }
    }

    /// Hands focus back to Rex once its view includes the latest request.
    private func settleRequestedFocus() {
        guard let revision = requestedFocusRevision, let viewRevision,
              viewRevision >= revision
        else { return }
        requestedFocus = nil
        requestedFocusRevision = nil
    }

    /// Keeps the panes on screen but stops them taking keystrokes, such as
    /// while Ghosthub checks a session that may replace this window.
    func setKeyboardInteractionSuspended(_ suspended: Bool) {
        keyboardSuspended = suspended
        for handle in paneHandles.values {
            coordinator.setKeyboardInteractionSuspended(suspended, handle: handle)
        }
    }

    func requestKeyboardFocus() {
        guard !keyboardSuspended, let focused = focusedPaneID,
              let handle = paneHandles[focused]
        else { return }
        coordinator.requestKeyboardFocus(handle: handle)
    }

    /// Closes the view. The panes keep running in Rex.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        channel.stop()
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        for handle in paneHandles.values {
            coordinator.detach(handle.selection)
        }
        paneHandles.removeAll()
        paneContents.removeAll()
        // The cards hold the terminal views; dropping them ends each pane's
        // attach client.
        container.apply(tree: nil, panes: [])
        let connection = sshConnection
        Task { try? await connection?.release() }
    }

    /// Stops the view and waits for its terminals and connections to close,
    /// as the scene does when it shuts down.
    func shutdown() async {
        let surfaces = Array(paneContents.values)
        stop()
        for surface in surfaces {
            await surface.shutdown()
        }
        await coordinator.shutdown()
        try? await sshConnection?.release()
    }

    // MARK: Views from Rex

    private func show(_ view: RexControlView) {
        guard !isStopped else { return }
        sessionID = view.sessionID
        guard let window = view.windows.first(where: { $0.id == selection.address }),
              let newTree = window.tree
        else {
            stop()
            onWindowClosed?()
            return
        }
        let previousFocus = focusedPaneID
        tree = newTree
        viewRevision = view.revision
        paneNames = view.paneNames
        windowLabel = window.label
        sessionLabel = view.sessionLabel
        paneDirectories = view.paneDirectories
        let blockIDs = Set(newTree.paneIDs)
        if let requested = requestedFocus, !blockIDs.contains(requested) {
            requestedFocus = nil
            requestedFocusRevision = nil
        }
        settleRequestedFocus()
        for (blockID, handle) in paneHandles where !blockIDs.contains(blockID) {
            coordinator.detach(handle.selection)
            paneHandles[blockID] = nil
            paneStates[blockID] = nil
            paneContents[blockID] = nil
            reconnectTasks.removeValue(forKey: blockID)?.cancel()
            reconnectAttempts[blockID] = nil
        }
        for blockID in newTree.paneIDs where paneHandles[blockID] == nil {
            attach(blockID)
        }
        render()
        if focusedPaneID != previousFocus {
            requestKeyboardFocus()
        }
        onChange?()
    }

    private func attach(_ blockID: String) {
        let handle = coordinator.attach(
            WorkspaceBackendTerminalSelection(
                hostID: selection.hostID, kind: selection.kind, address: blockID
            ),
            host: host,
            validated: validated
        )
        paneHandles[blockID] = handle
        paneStates[blockID] = .connecting
        if keyboardSuspended {
            coordinator.setKeyboardInteractionSuspended(true, handle: handle)
        }
    }

    private func render() {
        guard let tree = shownTree else { return }
        // Only the focused pane may take keyboard focus as it appears or
        // its window becomes key; any other would report itself to Rex.
        for (blockID, handle) in paneHandles {
            coordinator.setAutoFocusSuppressed(blockID != tree.focusedPaneID, handle: handle)
        }
        container.apply(tree: tree, panes: tree.paneIDs.map { blockID in
            var pane = TerminalSplitContainerView.Pane(
                id: blockID, title: title(ofPane: blockID), content: paneContents[blockID]
            )
            if case let .disconnected(reason) = paneStates[blockID] {
                if reconnectTasks[blockID] != nil {
                    pane.overlayMessage = "Reconnecting…"
                } else {
                    pane.overlayMessage = reason ?? "This pane is no longer attached."
                    pane.offersReconnect = true
                }
            }
            return pane
        })
    }

    // MARK: Pane attachments

    private func paneReady(_ handle: BorrowedBackendTerminalHandle) {
        guard let blockID = blockID(of: handle) else { return }
        if let surface = coordinator.surface(handle: handle) {
            if isLayoutEditable {
                surface.paneSplitShortcutHandler = { [weak self] direction in
                    self?.split(direction, from: blockID)
                }
            }
            surface.registerPaneFocusObserver(
                id: UUID(),
                onFocusChange: { [weak self] focused in
                    if focused {
                        self?.paneFocused(blockID)
                    }
                },
                onPrimaryInteraction: { [weak self] in
                    self?.panePressed(blockID)
                }
            )
            paneContents[blockID] = surface
        }
        render()
        if blockID == focusedPaneID, !keyboardSuspended {
            coordinator.requestKeyboardFocus(handle: handle)
        }
    }

    private func paneStateChanged(
        _ handle: BorrowedBackendTerminalHandle,
        _ state: ConnectionState
    ) {
        guard let blockID = blockID(of: handle) else { return }
        paneStates[blockID] = state
        switch state {
        case .connected:
            reconnectAttempts[blockID] = nil
        case .disconnected:
            paneContents[blockID] = nil
            if coordinator.reconnectsAutomatically(handle) {
                scheduleReconnect(blockID)
            }
        default:
            break
        }
        render()
    }

    /// Attaches a pane again after a delay that grows with each attempt.
    private func scheduleReconnect(_ blockID: String) {
        let attempt = reconnectAttempts[blockID, default: 0]
        reconnectAttempts[blockID] = attempt + 1
        let waitForReconnect = waitForReconnect
        reconnectTasks[blockID]?.cancel()
        reconnectTasks[blockID] = Task { [weak self] in
            try? await waitForReconnect(attempt)
            guard !Task.isCancelled else { return }
            self?.reconnectPane(blockID)
        }
    }

    /// Replaces a pane's lost attachment with a new one. Rex still has the
    /// pane, so its program and screen are as it left them.
    func reconnectPane(_ blockID: String) {
        reconnectTasks.removeValue(forKey: blockID)?.cancel()
        guard !isStopped, tree?.paneIDs.contains(blockID) == true,
              let old = paneHandles[blockID]
        else { return }
        coordinator.detach(old.selection)
        paneContents[blockID] = nil
        attach(blockID)
        render()
    }

    private func blockID(of handle: BorrowedBackendTerminalHandle) -> String? {
        let blockID = handle.selection.address
        return paneHandles[blockID] == handle ? blockID : nil
    }

    // MARK: Helpers

    private func headerAction(_ action: TerminalSplitHeaderAction, blockID: String) {
        switch action {
        case .splitRight: split(.right, from: blockID)
        case .splitDown: split(.down, from: blockID)
        case .float, .tile: toggleFloating(blockID)
        case .minimize: minimizeFloatingWindow(blockID)
        case .zoom: toggleZoom(blockID)
        case .close: onCloseRequested?(blockID)
        }
    }

    /// Brings the floating window that holds the pane to the front.
    private func raiseLayer(holding blockID: String) {
        guard let tree, let layer = tree.floatingLayer(holding: blockID),
              tree.floatingLayers.last(where: { !$0.isMinimized })?.id != layer.id
        else { return }
        request("session.raise_layer", ["layer_id": layer.id])
    }

    private func moveLayer(_ layerID: String, to bounds: CGRect) {
        request("session.resize_layer", [
            "layer_id": layerID, "bounds": Self.boundsValue(bounds),
        ]) { [weak self] in
            self?.container.discardCommittedBounds(layerID: layerID)
        }
    }

    private func showLayer(_ layerID: String) {
        request("session.set_layer_state", [
            "layer_id": layerID, "state": "normal", "focus": true,
        ])
    }

    /// Where a new floating window goes: the middle of the window, a
    /// little lower and to the right for each one already shown, so none
    /// hides another exactly.
    private func newFloatingBounds() -> CGRect {
        let shown = tree?.floatingLayers.count { !$0.isMinimized } ?? 0
        let step = 0.03 * Double(shown % 5)
        return CGRect(x: 0.2 + step, y: 0.15 + step, width: 0.6, height: 0.6)
    }

    /// The tiled pane a floating pane returns beside: the one under the
    /// middle of its floating window, else the first.
    private func tilingAnchor(for blockID: String) -> String? {
        guard let tree, let root = tree.root else { return nil }
        let tiled = root.paneIDs
        let layout = TerminalSplitLayout.layout(
            tree, in: container.bounds, metrics: container.metrics, scale: 1
        )
        let layer = tree.floatingLayer(holding: blockID)
        if let frame = layout.floatingLayers.first(where: { $0.id == layer?.id })?.frame,
           let under = tiled.first(where: {
               layout.panes[$0]?.contains(CGPoint(x: frame.midX, y: frame.midY)) == true
           }) {
            return under
        }
        return tiled.first
    }

    private static func boundsValue(_ bounds: CGRect) -> [Double] {
        [bounds.minX, bounds.minY, bounds.width, bounds.height].map(Double.init)
    }

    private func resize(_ divider: TerminalSplitDivider, to ratio: Double) {
        request("session.resize_pane", [
            "before_block_id": divider.firstPaneID,
            "after_block_id": divider.secondPaneID,
            "direction": divider.axis == .horizontal ? "horizontal" : "vertical",
            "ratio": ratio,
        ]) { [weak self] in
            self?.container.discardCommittedRatio(splitID: divider.splitID)
        }
    }

    private func request(
        _ method: String,
        _ params: [String: any Sendable],
        onFailure: (@MainActor () -> Void)? = nil,
        onSuccess: (@MainActor (Int?) -> Void)? = nil
    ) {
        guard !isStopped else { return }
        let channel = channel
        Task { @MainActor in
            do {
                let revision = try await channel.send(method: method, params: params)
                onSuccess?(revision)
            } catch is CancellationError {
                return
            } catch {
                AppLogger.shared.error(
                    "Rex \(method) failed: \(error)", context: "rex-window"
                )
                onFailure?()
            }
        }
    }

    private func channelExited(_ exit: RexControlChannelExit) {
        guard !isStopped else { return }
        stop()
        switch exit {
        case .ended:
            onWindowClosed?()
        case let .failed(message):
            onChannelFailed?(message)
        }
    }
}
