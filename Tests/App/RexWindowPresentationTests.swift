import Foundation
import GhosthubBackendTerminal
import GhosthubTerminal
@testable import GhosthubTerminalSupport
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@MainActor
final class FakeRexControlChannel: RexControlChannelling {
    var onView: ((RexControlView) -> Void)?
    var onExit: ((RexControlChannelExit) -> Void)?
    private(set) var requests: [(method: String, params: NSDictionary)] = []
    private(set) var isStopped = false
    var failure: (any Error)?
    /// The session's revision. Each request moves it on, as a change in
    /// Rex would, and a view shows it unless the test names an older one.
    private(set) var revision = 1
    /// Holds each reply until `answerHeldRequests`, as a slow Rex would.
    var holdsReplies = false
    private var heldReplies: [CheckedContinuation<Void, Never>] = []

    func send(method: String, params: [String: any Sendable]) async throws -> Int? {
        requests.append((method, NSDictionary(dictionary: params)))
        revision += 1
        let revision = revision
        if holdsReplies {
            await withCheckedContinuation { heldReplies.append($0) }
        }
        if let failure {
            throw failure
        }
        return revision
    }

    func answerHeldRequests() {
        holdsReplies = false
        let held = heldReplies
        heldReplies.removeAll()
        held.forEach { $0.resume() }
    }

    func stop() {
        isStopped = true
    }

    /// Delivers a view of `window:1` in session `session:s`.
    func deliver(
        layout: String, focused: String, window: String = "window:1", revision: Int? = nil,
        terminals: String = "{}", windowLabel: String = "w", blocks: String = "[]",
        floating: String = ""
    ) throws {
        let line = """
        {"type":"view","terminals":\(terminals),"view":{"revision":\(revision ?? self.revision),"session_id":"session:s","label":"work",
         "windows":[{"window_id":"\(window)","label":"\(windowLabel)","focused_block_id":"\(focused)",
         "layers":[{"kind":"tiled","layout":\(layout),"blocks":\(blocks)}\(floating)]}]}}
        """
        guard case let .view(view) = try RexControlMessage.decode(line: Data(line.utf8)) else {
            Issue.record("not a view")
            return
        }
        onView?(view)
    }
}

@MainActor
@Suite("Rex window presentation", .timeLimit(.minutes(1)))
struct RexWindowPresentationTests {
    private static let one = #"{"block_id":"block:a"}"#
    private static let two = #"""
    {"split":{"split_id":"split:1","direction":"horizontal","ratio":0.5,
     "before":{"block_id":"block:a"},"after":{"block_id":"block:b"}}}
    """#

    private struct RetryableLaunchError: Error {}

    private let hostID = UUID()
    private let channel = FakeRexControlChannel()
    private let store: RecordingNativeSessionSurfaceStore

    init() {
        store = RecordingNativeSessionSurfaceStore(viewPerSurface: true)
    }

    init(failingRetryably: Void) {
        store = RecordingNativeSessionSurfaceStore(
            launchError: RetryableLaunchError(), launchFailureIsRetryable: true
        )
    }

    private func presentation(
        waitForReconnect: @escaping @MainActor (Int) async throws -> Void = { _ in
            try await Task.sleep(for: .milliseconds(10))
        }
    ) -> RexWindowPresentation {
        let coordinator = NativeBackendTerminalCoordinator(
            terminalCoordinator: store,
            executableProvider: { _, _, _ in .success("/kwt") }
        )
        let presentation = RexWindowPresentation(
            selection: WorkspaceBackendTerminalSelection(
                hostID: hostID, kind: .rex, address: "window:1"
            ),
            host: .local,
            validated: SSHConnectionArgumentsSnapshot(arguments: []),
            channel: channel,
            coordinator: coordinator,
            waitForReconnect: waitForReconnect
        )
        presentation.container.frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
        return presentation
    }

    private func waitUntil(_ condition: () -> Bool) async {
        while !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func surface(
        _ presentation: RexWindowPresentation,
        _ blockID: String
    ) -> RecordingNativeSessionPaneSurface? {
        guard let handle = presentation.paneHandles[blockID] else { return nil }
        return store.paneSurfaceIfPresent(for: SurfaceKey(
            worktreeID: handle.id,
            hostID: handle.hostID,
            target: .backendTerminal,
            leafID: handle.surfaceID
        )) as? RecordingNativeSessionPaneSurface
    }

    /// Lets requests already queued reach the channel, so a check that none
    /// was sent cannot pass early.
    private func sendsSettle() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func lastRequest(_ count: Int) async -> (method: String, params: NSDictionary)? {
        await waitUntil { channel.requests.count >= count }
        return channel.requests.last
    }

    @Test("each pane attaches once; a pane that stays keeps its terminal")
    func panes() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.one, focused: "block:a")
        await waitUntil { store.requestedKeys.count == 1 }
        let a = try #require(presentation.paneHandles["block:a"])

        try channel.deliver(layout: Self.two, focused: "block:b")
        await waitUntil { store.requestedKeys.count == 2 }
        #expect(presentation.paneHandles["block:a"] == a)
        #expect(store.removedKeys.isEmpty)
        #expect(presentation.tree?.paneIDs == ["block:a", "block:b"])
        #expect(store.requestedConfigurations.allSatisfy {
            $0.command?.contains("rex") == true && $0.command?.contains("attach") == true
        })

        try channel.deliver(layout: #"{"block_id":"block:b"}"#, focused: "block:b")
        #expect(presentation.paneHandles["block:a"] == nil)
        #expect(store.removedKeys.map(\.worktreeID) == [a.id])
        #expect(presentation.container.paneViews.keys.sorted() == ["block:b"])
    }

    @Test("Rex moving focus moves keyboard focus to that pane")
    func focusFollowsRex() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { store.requestedKeys.count == 2 }
        let b = try #require(surface(presentation, "block:b"))
        let before = b.keyboardFocusRequestCount
        try channel.deliver(layout: Self.two, focused: "block:b")
        #expect(b.keyboardFocusRequestCount == before + 1)
    }

    @Test("splitting sends new_split beside the focused pane, focused, with a shell")
    func split() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:b")
        presentation.split(.right)
        let request = try #require(await lastRequest(1))
        #expect(request.method == "session.new_split")
        #expect(request.params == [
            "anchor_id": "block:b", "direction": "horizontal", "side": "after", "focus": true,
            "layout": ["block": ["flavor": "com.superlogical.terminal.shell"]],
        ] as NSDictionary)
        presentation.split(.down)
        #expect(await lastRequest(2)?.params["direction"] as? String == "vertical")
    }

    @Test("a split starts its shell in the anchor pane's directory")
    func splitDirectory() async throws {
        let presentation = presentation()
        try channel.deliver(
            layout: Self.two, focused: "block:b",
            terminals: #"{"block:b":{"name":"zsh ~/src/app","cwd":"/home/user-a/src/app"}}"#
        )
        presentation.split(.right)
        #expect(await lastRequest(1)?.params["layout"] as? NSDictionary == [
            "block": [
                "flavor": "com.superlogical.terminal.shell",
                "options": ["cwd": "/home/user-a/src/app"],
            ],
        ] as NSDictionary)
    }

    @Test("focus moves stay in this window, name the pane, and chain before Rex replies")
    func moveFocus() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        #expect(presentation.moveFocus(.right))
        let request = try #require(await lastRequest(1))
        #expect(request.method == "session.focus_block")
        #expect(request.params == ["block_id": "block:b"] as NSDictionary)
        #expect(!presentation.moveFocus(.right))
        #expect(presentation.moveFocus(.left))
        #expect(await lastRequest(2)?.params == ["block_id": "block:a"] as NSDictionary)
    }

    @Test("a divider drag sends one resize naming the panes beside it")
    func resize() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        presentation.container.layoutSubtreeIfNeeded()
        let divider = try #require(presentation.container.dividers.first)
        presentation.container.onResizeCommitted?(divider, 0.3)
        let request = try #require(await lastRequest(1))
        #expect(request.method == "session.resize_pane")
        #expect(request.params == [
            "before_block_id": "block:a", "after_block_id": "block:b",
            "direction": "horizontal", "ratio": 0.3,
        ] as NSDictionary)
    }

    /// Floating windows over the tiled panes: C in the middle, D minimized
    /// in the corner.
    private static let floating = #"""
    ,{"kind":"floating","layer_id":"layer:c","bounds":[0.25,0.25,0.5,0.5],
      "layout":{"block_id":"block:c"}},
     {"kind":"floating","layer_id":"layer:d","bounds":[0,0,0.2,0.2],"state":"minimized",
      "layout":{"block_id":"block:d"}}
    """#

    @Test("a window with only floating panes stays open and attaches them")
    func onlyFloating() async throws {
        let presentation = presentation()
        var closed = false
        presentation.onWindowClosed = { closed = true }
        try channel.deliver(layout: "null", focused: "block:c", floating: Self.floating)
        await waitUntil { store.requestedKeys.count == 2 }
        presentation.container.layoutSubtreeIfNeeded()
        #expect(!closed)
        #expect(presentation.tree?.root == nil)
        #expect(presentation.paneHandles.keys.sorted() == ["block:c", "block:d"])
        #expect(presentation.container.paneViews["block:c"]?.isHidden == false)
        #expect(presentation.container.paneViews["block:d"]?.isHidden == true)
    }

    @Test("Float Pane floats a tiled pane; on a floating pane it tiles it beside the pane under it")
    func toggleFloating() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a", floating: Self.floating)
        presentation.container.layoutSubtreeIfNeeded()

        presentation.toggleFloating()
        let float = try #require(await lastRequest(1))
        #expect(float.method == "session.float_block")
        // One floating window shows, so the new one sits a step lower.
        #expect(float.params == [
            "block_id": "block:a", "bounds": [0.23, 0.18, 0.6, 0.6],
        ] as NSDictionary)

        // Over the right half, C returns beside B, not the first pane.
        try channel.deliver(
            layout: Self.two, focused: "block:a",
            floating: Self.floating.replacingOccurrences(of: "0.25,0.25", with: "0.45,0.25")
        )
        presentation.container.layoutSubtreeIfNeeded()
        presentation.toggleFloating("block:c")
        let tile = try #require(await lastRequest(2))
        #expect(tile.method == "session.move_block")
        #expect(tile.params == [
            "block_id": "block:c", "anchor_block_id": "block:b",
            "direction": "horizontal", "side": "after",
        ] as NSDictionary)
    }

    @Test("New Floating Pane opens a shell in the focused pane's directory, in front")
    func newFloatingPane() async throws {
        let presentation = presentation()
        try channel.deliver(
            layout: Self.two, focused: "block:b",
            terminals: #"{"block:b":{"name":"zsh","cwd":"/home/user-a"}}"#
        )
        presentation.newFloatingPane()
        let request = try #require(await lastRequest(1))
        #expect(request.method == "session.new_layer")
        #expect(request.params == [
            "window_id": "window:1", "bounds": [0.2, 0.15, 0.6, 0.6], "focus": true,
            "layout": ["block": [
                "flavor": "com.superlogical.terminal.shell",
                "options": ["cwd": "/home/user-a"],
            ]],
        ] as NSDictionary)
    }

    @Test("minimizing hides the pane's floating window; its capsule shows it again")
    func minimizeAndRestore() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:c", floating: Self.floating)
        presentation.container.layoutSubtreeIfNeeded()
        #expect(presentation.canMinimizeFocusedFloatingWindow)

        presentation.minimizeFloatingWindow()
        #expect(await lastRequest(1)?.params == [
            "layer_id": "layer:c", "state": "minimized",
        ] as NSDictionary)
        #expect(channel.requests.last?.method == "session.set_layer_state")

        presentation.container.capsules["layer:d"]?.performClick(nil)
        #expect(await lastRequest(2)?.params == [
            "layer_id": "layer:d", "state": "normal", "focus": true,
        ] as NSDictionary)

        try channel.deliver(layout: Self.two, focused: "block:a", floating: Self.floating)
        #expect(!presentation.canMinimizeFocusedFloatingWindow)
    }

    @Test("clicking a pane in a floating window behind another brings it to the front")
    func clickRaisesWindow() async throws {
        let presentation = presentation()
        let behind = #"""
        ,{"kind":"floating","layer_id":"layer:c","bounds":[0.1,0.1,0.5,0.5],
          "layout":{"block_id":"block:c"}},
         {"kind":"floating","layer_id":"layer:e","bounds":[0.3,0.3,0.5,0.5],
          "layout":{"block_id":"block:e"}}
        """#
        // Another Rex app raised layer:e; Ghosthub still has block:c focused.
        try channel.deliver(layout: Self.two, focused: "block:c", floating: behind)

        presentation.panePressed("block:c")
        let request = try #require(await lastRequest(1))
        #expect(request.method == "session.raise_layer")
        #expect(request.params == ["layer_id": "layer:c"] as NSDictionary)

        presentation.panePressed("block:e")
        presentation.panePressed("block:a")
        try await sendsSettle()
        #expect(channel.requests.count == 1)
    }

    @Test("moving or resizing a floating window sends its new bounds")
    func moveFloatingWindow() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a", floating: Self.floating)
        presentation.container.onLayerBoundsCommitted?(
            "layer:c", CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25)
        )
        let request = try #require(await lastRequest(1))
        #expect(request.method == "session.resize_layer")
        #expect(request.params == [
            "layer_id": "layer:c", "bounds": [0.1, 0.2, 0.5, 0.25],
        ] as NSDictionary)
    }

    @Test("the close button asks first; closing sends block.close")
    func close() async throws {
        let presentation = presentation()
        var asked: [String] = []
        presentation.onCloseRequested = { asked.append($0) }
        try channel.deliver(layout: Self.two, focused: "block:a")
        presentation.container.onHeaderAction?("block:b", .close)
        #expect(asked == ["block:b"])
        try await sendsSettle()
        #expect(channel.requests.isEmpty)
        presentation.closePane("block:b")
        let request = try #require(await lastRequest(1))
        #expect(request.method == "block.close")
        #expect(request.params == ["block_id": "block:b"] as NSDictionary)
        presentation.stop()
        presentation.closePane("block:a")
        try await sendsSettle()
        #expect(channel.requests.count == 1)
    }

    @Test("the window closing, or its session ending, closes the view", arguments: [true, false])
    func windowGone(sessionEnded: Bool) async throws {
        let presentation = presentation()
        var closed = 0
        presentation.onWindowClosed = { closed += 1 }
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { store.requestedKeys.count == 2 }
        if sessionEnded {
            channel.onExit?(.ended)
        } else {
            try channel.deliver(layout: Self.one, focused: "block:a", window: "window:2")
        }
        #expect(closed == 1)
        #expect(channel.isStopped)
        #expect(presentation.paneHandles.isEmpty)
        #expect(store.removedKeys.count == 2)
    }

    @Test("losing kwt rex control reports its message")
    func channelLost() throws {
        let presentation = presentation()
        var failures: [String] = []
        presentation.onChannelFailed = { failures.append($0) }
        try channel.deliver(layout: Self.one, focused: "block:a")
        channel.onExit?(.failed("rex: server went away"))
        #expect(failures == ["rex: server went away"])
        #expect(presentation.isStopped)
    }

    @Test("stopping detaches every pane without closing any")
    func stop() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { store.requestedKeys.count == 2 }
        presentation.stop()
        #expect(channel.isStopped)
        #expect(store.removedKeys.count == 2)
        try await sendsSettle()
        #expect(channel.requests.isEmpty)
        #expect(presentation.container.paneViews.isEmpty, "a card would keep its terminal alive")
    }

    @Test("only the focused pane may take keyboard focus by itself")
    func autoFocus() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { surface(presentation, "block:a") != nil && surface(
            presentation,
            "block:b"
        ) != nil }
        let a = try #require(surface(presentation, "block:a"))
        let b = try #require(surface(presentation, "block:b"))
        #expect(!a.suppressAutoFocus && b.suppressAutoFocus)
        // libghostty starts each terminal focused, so its cursor would blink.
        #expect(b.focusStates.last == false)
        #expect(!a.focusStates.contains(false))

        try channel.deliver(layout: Self.two, focused: "block:b")
        #expect(a.suppressAutoFocus && !b.suppressAutoFocus)
        #expect(a.focusStates.last == false)
    }

    @Test("a later click is kept while Rex still reports an earlier one")
    func laggingFocus() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { surface(presentation, "block:b") != nil }
        let a = try #require(surface(presentation, "block:a"))

        presentation.paneFocused("block:b")
        presentation.paneFocused("block:a")
        #expect(await lastRequest(2)?.params == ["block_id": "block:a"] as NSDictionary)

        // Rex reports the first click before the second.
        let before = a.keyboardFocusRequestCount
        try channel.deliver(layout: Self.two, focused: "block:b", revision: 2)
        #expect(presentation.focusedPaneID == "block:a")
        #expect(presentation.container.paneViews["block:a"]?.isFocused == true)
        #expect(a.keyboardFocusRequestCount == before)
        try channel.deliver(layout: Self.two, focused: "block:a", revision: 3)
        #expect(presentation.focusedPaneID == "block:a")
    }

    @Test("a choice made again is kept until Rex shows the latest request")
    func repeatedFocusChoice() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { surface(presentation, "block:b") != nil }
        let a = try #require(surface(presentation, "block:a"))
        channel.holdsReplies = true

        presentation.paneFocused("block:b")
        presentation.paneFocused("block:a")
        presentation.paneFocused("block:b")
        await waitUntil { channel.requests.count == 3 }
        let before = a.keyboardFocusRequestCount

        // Rex shows each request in turn before answering any.
        for (focused, revision) in [("block:b", 2), ("block:a", 3), ("block:b", 4)] {
            try channel.deliver(layout: Self.two, focused: focused, revision: revision)
            #expect(presentation.focusedPaneID == "block:b")
        }
        channel.answerHeldRequests()
        try await sendsSettle()
        #expect(presentation.focusedPaneID == "block:b")
        #expect(a.keyboardFocusRequestCount == before)
    }

    @Test("a view older than the latest focus request cannot move focus")
    func olderViewAfterReply() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { surface(presentation, "block:b") != nil }
        let b = try #require(surface(presentation, "block:b"))

        presentation.paneFocused("block:b")
        presentation.paneFocused("block:a")
        await waitUntil { channel.requests.count == 2 }
        try await sendsSettle()
        let before = b.keyboardFocusRequestCount

        // Replies came first; then a view from before either request, then
        // Rex showing the first one.
        try channel.deliver(layout: Self.two, focused: "block:a", revision: 1)
        try channel.deliver(layout: Self.two, focused: "block:b", revision: 2)
        #expect(presentation.focusedPaneID == "block:a")
        #expect(b.keyboardFocusRequestCount == before)
        try channel.deliver(layout: Self.two, focused: "block:a", revision: 3)
        #expect(presentation.focusedPaneID == "block:a")
        #expect(b.keyboardFocusRequestCount == before)
    }

    @Test("the previous pane gives up typing when focus moves to another pane")
    func previousPaneResigns() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { surface(presentation, "block:b") != nil }
        let a = try #require(surface(presentation, "block:a"))

        // Clicking B, which may still be attaching.
        a.hasEffectiveKeyboardFocus = true
        presentation.paneFocused("block:b")
        #expect(!a.hasEffectiveKeyboardFocus)
        try await sendsSettle()

        // Rex moving focus while Ghosthub is in the background.
        try channel.deliver(layout: Self.two, focused: "block:b")
        presentation.paneFocused("block:a")
        try await sendsSettle()
        try channel.deliver(layout: Self.two, focused: "block:a")
        a.hasEffectiveKeyboardFocus = true
        try channel.deliver(layout: Self.two, focused: "block:b")
        #expect(!a.hasEffectiveKeyboardFocus)
    }

    @Test("clicking the chosen pane's header takes the keyboard back without asking Rex")
    func chosenPaneHeader() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { surface(presentation, "block:a") != nil }
        let a = try #require(surface(presentation, "block:a"))
        let before = a.keyboardFocusRequestCount

        presentation.container.onPaneClicked?("block:a")
        #expect(a.keyboardFocusRequestCount == before + 1)
        try await sendsSettle()
        #expect(channel.requests.isEmpty)
    }

    @Test("a pane that lost its connection attaches again by itself")
    func paneReconnects() async throws {
        let suite = RexWindowPresentationTests(failingRetryably: ())
        let (ticks, advance) = AsyncStream<Void>.makeStream()
        var retryAttempts: [Int] = []
        let presentation = suite.presentation { attempt in
            retryAttempts.append(attempt)
            var iterator = ticks.makeAsyncIterator()
            _ = await iterator.next()
        }
        defer {
            presentation.stop()
            advance.finish()
        }
        try suite.channel.deliver(layout: Self.one, focused: "block:a")
        await waitUntilMainActor { retryAttempts.count == 1 }
        advance.yield()
        await waitUntilMainActor { retryAttempts.count == 2 }
        #expect(retryAttempts == [0, 1])
        #expect(suite.store.requestedKeys.count == 2)
        #expect(presentation.container.paneViews["block:a"]?.overlayMessage == "Reconnecting…")

        suite.store.surface.launchError = nil
        advance.yield()
        await waitUntilMainActor {
            suite.store.surface.closeObservers.count == 1
                && presentation.container.paneViews["block:a"]?.overlayMessage == nil
        }
        #expect(suite.store.requestedKeys.count == 3)
        #expect(retryAttempts == [0, 1])
    }

    @Test("a pane that ended offers Reconnect, which attaches it again")
    func paneReconnectButton() async throws {
        let presentation = presentation()
        try channel.deliver(layout: Self.two, focused: "block:a")
        await waitUntil { surface(presentation, "block:b") != nil }
        let old = try #require(presentation.paneHandles["block:b"])
        let b = try #require(surface(presentation, "block:b"))

        b.closeObservers.values.first?(false, 1)
        let card = try #require(presentation.container.paneViews["block:b"])
        #expect(card.overlayMessage != nil)
        #expect(card.offersReconnect)

        let requested = store.requestedKeys.count
        presentation.container.onPaneReconnect?("block:b")
        await waitUntil { store.requestedKeys.count == requested + 1 }
        #expect(presentation.paneHandles["block:b"] != old)
        #expect(!card.offersReconnect)
    }
}
