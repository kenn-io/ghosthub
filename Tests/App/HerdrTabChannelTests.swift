import Foundation
import GhosthubBackendTerminal
import GhosthubTerminalSupport
import GhosthubTransport
import Synchronization
import Testing
@testable import GhosthubApp

/// Stands in for a core's event stream; tests call `onChange` themselves.
@MainActor
final class FakeHerdrCoreEvents: HerdrCoreEventFollowing {
    var onChange: (() -> Void)?
    var onExit: ((String) -> Void)?
    var stopped = false
    func stop() {
        stopped = true
    }
}

@MainActor
@Suite("Herdr desktop tab channel", .timeLimit(.minutes(1)))
struct HerdrTabChannelTests {
    private typealias FakeEvents = FakeHerdrCoreEvents

    private final class Recorder {
        var views: [RexControlView] = []
        var exits: [RexControlChannelExit] = []
    }

    /// Answers each listing with the next result, holding it until `gate`
    /// opens when one is set.
    private final class Listings: Sendable {
        let results: Mutex<[Result<HerdrCoreListing, BackendTerminalCommandError>]>
        let count = Mutex(0)
        let gate = Mutex<AsyncGate?>(nil)

        init(_ results: [Result<HerdrCoreListing, BackendTerminalCommandError>]) {
            self.results = Mutex(results)
        }

        func next() async -> Result<HerdrCoreListing, BackendTerminalCommandError> {
            count.withLock { $0 += 1 }
            if let gate = gate.withLock({ $0 }) {
                await gate.wait()
            }
            return results.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] }
        }
    }

    private static func listing(
        _ root: TerminalSplitTree.Node?,
        name: String = "ready"
    ) -> HerdrCoreListing {
        HerdrCoreListing(
            rows: [],
            tabs: root.map { [HerdrCoreTab(
                address: "tab:tb1",
                name: name,
                spaceName: "Review",
                root: $0
            )] } ?? [],
            paneNames: ["t1": "sh", "t2": "build-watch"],
            paneDirectories: ["t1": "/src"]
        )
    }

    private static let twoPanes = TerminalSplitTree.Node.split(
        id: "r#0", axis: .horizontal, ratio: 0.5, first: .pane("t1"), second: .pane("t2")
    )

    private func start(
        _ listings: Listings
    ) -> (HerdrTabChannel, FakeEvents, Recorder) {
        let events = FakeEvents()
        let channel = HerdrTabChannel(tabAddress: "tab:tb1", events: events) {
            await listings.next()
        }
        let recorder = Recorder()
        channel.onView = { recorder.views.append($0) }
        channel.onExit = { recorder.exits.append($0) }
        return (channel, events, recorder)
    }

    private func waitUntil(
        _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0 ..< 500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out", sourceLocation: sourceLocation)
    }

    @Test("the tab's panes show with the first one focused")
    func firstView() async {
        let (channel, _, recorder) = start(Listings([.success(Self.listing(Self.twoPanes))]))
        defer { channel.stop() }
        await waitUntil { !recorder.views.isEmpty }

        let view = recorder.views[0]
        #expect(view.sessionLabel == "Review")
        #expect(view.windows.map(\.id) == ["tab:tb1"])
        #expect(view.windows.first?.label == "ready")
        #expect(view.windows.first?.tree == TerminalSplitTree(
            root: Self.twoPanes,
            focusedPaneID: "t1"
        ))
        #expect(view.paneNames["t2"] == "build-watch")
        #expect(view.paneDirectories["t1"] == "/src")
    }

    @Test("focus and zoom stay in Ghosthub, and layout changes are refused")
    func localFocusAndZoom() async throws {
        let (channel, _, recorder) = start(Listings([.success(Self.listing(Self.twoPanes))]))
        defer { channel.stop() }
        await waitUntil { !recorder.views.isEmpty }

        let focused = try await channel.send(
            method: "session.focus_block",
            params: ["block_id": "t2"]
        )
        try await channel.send(method: "session.zoom_block", params: ["block_id": "t2"])
        #expect(focused == recorder.views[1].revision)
        #expect(recorder.views.last?.windows.first?.tree?.focusedPaneID == "t2")
        #expect(recorder.views.last?.windows.first?.tree?.zoomedPaneID == "t2")
        try await channel.send(method: "session.zoom_block", params: ["block_id": "t2"])
        #expect(recorder.views.last?.windows.first?.tree?.zoomedPaneID == nil)

        for method in [
            "session.new_split",
            "block.close",
            "session.resize_pane",
            "session.float_block",
        ] {
            await #expect(throws: HerdrTabChannel.readOnly) {
                try await channel.send(method: method, params: ["block_id": "t1"])
            }
        }
    }

    @Test("moving focus while zoomed zooms the newly focused pane")
    func focusWhileZoomed() async throws {
        let (channel, _, recorder) = start(Listings([.success(Self.listing(Self.twoPanes))]))
        defer { channel.stop() }
        await waitUntil { !recorder.views.isEmpty }

        try await channel.send(method: "session.zoom_block", params: ["block_id": "t1"])
        try await channel.send(method: "session.focus_block", params: ["block_id": "t2"])
        let tree = recorder.views.last?.windows.first?.tree
        #expect(tree?.focusedPaneID == "t2")
        #expect(tree?.zoomedPaneID == "t2")
    }

    @Test("a change in the core shows the tab's new layout and keeps the focused pane")
    func change() async throws {
        let listings = Listings([
            .success(Self.listing(Self.twoPanes)),
            .success(Self.listing(.split(
                id: "r#0", axis: .vertical, ratio: 0.3, first: .pane("t1"), second: .pane("t2")
            ), name: "renamed")),
        ])
        let (channel, events, recorder) = start(listings)
        defer { channel.stop() }
        await waitUntil { !recorder.views.isEmpty }
        try await channel.send(method: "session.focus_block", params: ["block_id": "t2"])

        events.onChange?()
        await waitUntil { recorder.views.last?.windows.first?.label == "renamed" }
        #expect(recorder.views.last?.windows.first?.tree?.focusedPaneID == "t2")
    }

    @Test("changes during a listing cost one more listing, not one each")
    func coalescedChanges() async {
        let listings = Listings([.success(Self.listing(Self.twoPanes))])
        let (channel, events, recorder) = start(listings)
        defer { channel.stop() }
        await waitUntil { !recorder.views.isEmpty }
        let gate = AsyncGate()
        listings.gate.withLock { $0 = gate }

        events.onChange?()
        events.onChange?()
        events.onChange?()
        await waitUntil { listings.count.withLock { $0 } == 2 }
        listings.gate.withLock { $0 = nil }
        gate.open()
        await waitUntil { recorder.views.count == 3 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(listings.count.withLock { $0 } == 3)
    }

    @Test("a tab closed in Herdr ends the view")
    func tabClosed() async {
        let listings = Listings([
            .success(Self.listing(Self.twoPanes)),
            .success(Self.listing(nil)),
        ])
        let (channel, events, recorder) = start(listings)
        await waitUntil { !recorder.views.isEmpty }

        events.onChange?()
        await waitUntil { !recorder.exits.isEmpty }
        withExtendedLifetime(channel) {}
        #expect(recorder.exits == [.ended])
        #expect(events.stopped)
    }

    @Test("a tab missing from one listing stays open when the next one has it")
    func tabBrieflyMissing() async {
        let listings = Listings([
            .success(Self.listing(Self.twoPanes)),
            .success(Self.listing(nil)),
            .success(Self.listing(Self.twoPanes, name: "back")),
        ])
        let (channel, events, recorder) = start(listings)
        defer { channel.stop() }
        await waitUntil { !recorder.views.isEmpty }

        events.onChange?()
        await waitUntil { recorder.views.last?.windows.first?.label == "back" }
        #expect(recorder.exits.isEmpty)
        #expect(!events.stopped)
    }

    @Test("a failed listing or a stopped event stream is reported once")
    func failures() async {
        let listed = start(Listings([.failure(.unavailable(.herdrCore))]))
        await waitUntil { !listed.2.exits.isEmpty }
        withExtendedLifetime(listed.0) {}
        #expect(listed.2.exits.count == 1)
        #expect(listed.1.stopped)

        let streamed = start(Listings([.success(Self.listing(Self.twoPanes))]))
        await waitUntil { !streamed.2.views.isEmpty }
        streamed.1.onExit?("hc: lost the core")
        streamed.1.onExit?("again")
        withExtendedLifetime(streamed.0) {}
        #expect(streamed.2.exits == [.failed("hc: lost the core")])
    }
}

@MainActor
@Suite("Herdr Core event stream", .timeLimit(.minutes(1)))
struct HerdrCoreEventStreamTests {
    /// Stands in for `herdr-core connect` behind a login shell that prints a
    /// banner. It echoes the subscription request to stderr, answers it,
    /// then writes the events in `GHOSTHUB_FAKE_EVENTS` and exits.
    private static func fakeCore(
        events: [String],
        reply: String = #"{"id":1,"jsonrpc":"2.0","result":{"seq":1,"terminals":[]}}"#
    ) -> String {
        let lines = ([reply] + events).map(shellQuotedCommandArgument).joined(separator: " ")
        return """
        echo 'Welcome to devbox'
        printf '%s\\n' 'GHOSTHUB_HC_EVENTS'
        IFS= read -r request
        printf '%s\\n' "$request" >&2
        printf '%s\\n' \(lines)
        sleep 0.2
        exit 1
        """
    }

    private final class Recorder {
        var changes = 0
        var exits: [String] = []
    }

    private func follow(_ command: String) throws -> (HerdrCoreEventStream, Recorder) {
        let stream = try HerdrCoreEventStream(command: command)
        let recorder = Recorder()
        stream.onChange = { recorder.changes += 1 }
        stream.onExit = { recorder.exits.append($0) }
        return (stream, recorder)
    }

    private func waitUntil(
        _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0 ..< 500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out", sourceLocation: sourceLocation)
    }

    @Test("layout, terminal, and missed events are changes; frequent status events are not")
    func changes() async throws {
        let event = { (type: String) in
            #"{"jsonrpc":"2.0","method":"event","params":{"seq":2,"type":"\#(type)","terminal":"t1","data":{}}}"#
        }
        let (stream, recorder) = try follow(Self.fakeCore(events: [
            event("foreground"), event("status"), event("size"), event("turn"),
            #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":2}}"#,
            event("doc"), event("created"), event("finished"), event("removed"),
            event("restarted"), event("labels"), event("title"),
            #"{"jsonrpc":"2.0","method":"missed","params":{"seq":9,"terminals":[]}}"#,
        ]))
        await waitUntil { !recorder.exits.isEmpty }
        withExtendedLifetime(stream) {}

        // The confirmed subscription counts too.
        #expect(recorder.changes == 9)
        // The exit carries what the fake wrote to stderr: the request it read.
        #expect(recorder.exits.first?.contains(#""method":"events.subscribe""#) == true)
    }

    @Test("a confirmed subscription counts as a change, for anything missed while it started")
    func subscribed() async throws {
        let (stream, recorder) = try follow(Self.fakeCore(events: []))
        await waitUntil { !recorder.exits.isEmpty }
        withExtendedLifetime(stream) {}
        #expect(recorder.changes == 1)
    }

    @Test("a refused subscription or an unreadable line stops the stream", arguments: [
        (
            #"{"id":1,"jsonrpc":"2.0","error":{"code":-32601,"message":"no method events.subscribe"}}"#,
            [String](),
            "no method events.subscribe",
            0
        ),
        (
            #"{"id":1,"jsonrpc":"2.0","result":{}}"#, ["not json"],
            "Cannot update this Herdr tab.", 1
        ),
    ])
    func refused(_ reply: String, events: [String], message: String, changes: Int) async throws {
        let (stream, recorder) = try follow(Self.fakeCore(events: events, reply: reply))
        await waitUntil { !recorder.exits.isEmpty }
        withExtendedLifetime(stream) {}

        #expect(recorder.changes == changes)
        #expect(recorder.exits == [message])
    }
}
