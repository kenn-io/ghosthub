import Foundation
import GhosthubBackendTerminal
import GhosthubTerminalSupport
import GhosthubTransport

/// Starts following a Herdr desktop tab, from its `tab:` address, its
/// `herdr-core connect` command, and a way to list the host again.
typealias HerdrTabChannelFactory = @MainActor (
    String, String, @escaping HerdrTabChannel.Listing
) throws -> any RexControlChannelling

/// Reports when a Herdr Core's terminals or documents may have changed.
@MainActor
protocol HerdrCoreEventFollowing: AnyObject {
    var onChange: (() -> Void)? { get set }
    /// The stream stopped, with why.
    var onExit: ((String) -> Void)? { get set }
    func stop()
}

/// Follows one Herdr desktop tab for `RexWindowPresentation`. The Herdr
/// desktop app owns the tab's layout, so this channel only reads it: it
/// lists the host again whenever the core reports a change that can move a
/// pane, and keeps focus and zoom to itself. Layout changes are refused.
@MainActor
final class HerdrTabChannel: RexControlChannelling {
    typealias Listing = @Sendable () async -> Result<HerdrCoreListing, BackendTerminalCommandError>

    static let readOnly = RexControlError(
        code: "read_only", message: "Change this tab's layout in Herdr."
    )

    var onView: ((RexControlView) -> Void)?
    var onExit: ((RexControlChannelExit) -> Void)?

    private let tabAddress: String
    private let events: any HerdrCoreEventFollowing
    private let list: Listing
    private var tab: HerdrCoreTab?
    private var listing: HerdrCoreListing?
    private var focused: String?
    private var zoomed: String?
    private var revision = 0
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    /// The last listing lacked the tab. One more listing confirms it is
    /// gone: a terminal replaced between a listing's reads looks absent.
    private var tabMissing = false
    private var finished = false

    init(tabAddress: String, events: any HerdrCoreEventFollowing, list: @escaping Listing) {
        self.tabAddress = tabAddress
        self.events = events
        self.list = list
        events.onChange = { [weak self] in self?.refresh() }
        events.onExit = { [weak self] message in self?.fail(message) }
        refresh()
    }

    @discardableResult
    func send(method: String, params: [String: any Sendable]) async throws -> Int? {
        guard !finished else { throw CancellationError() }
        let block = params["block_id"] as? String
        switch method {
        case "session.focus_block":
            guard let block, tab?.root.paneIDs.contains(block) == true else { break }
            focused = block
            // A zoomed view shows only the focused pane.
            if zoomed != nil {
                zoomed = block
            }
        case "session.zoom_block":
            guard let block, tab?.root.paneIDs.contains(block) == true else { break }
            zoomed = zoomed == block ? nil : block
        default:
            throw Self.readOnly
        }
        showTab()
        return revision
    }

    func stop() {
        guard !finished else { return }
        finished = true
        refreshTask?.cancel()
        refreshTask = nil
        events.stop()
    }

    /// Lists the host again, once more after the current listing if a
    /// change arrives during it.
    private func refresh() {
        guard !finished else { return }
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        let list = list
        refreshTask = Task { [weak self] in
            let result = await list()
            self?.listed(result)
        }
    }

    private func listed(_ result: Result<HerdrCoreListing, BackendTerminalCommandError>) {
        refreshTask = nil
        guard !finished, !Task.isCancelled else { return }
        switch result {
        case let .failure(error):
            fail(error.localizedDescription)
            return
        case let .success(listing):
            guard let tab = listing.tabs.first(where: { $0.address == tabAddress }) else {
                if tabMissing {
                    stop()
                    onExit?(.ended)
                } else {
                    tabMissing = true
                    refreshAgain = false
                    refresh()
                }
                return
            }
            tabMissing = false
            self.listing = listing
            self.tab = tab
        }
        showTab()
        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    private func showTab() {
        guard let tab, let listing else { return }
        let panes = tab.root.paneIDs
        if focused.map(panes.contains) != true {
            focused = panes.first
        }
        if zoomed.map(panes.contains) != true {
            zoomed = nil
        }
        revision += 1
        onView?(RexControlView(
            revision: revision,
            sessionID: tabAddress,
            sessionLabel: tab.spaceName,
            windows: [RexControlView.Window(
                id: tabAddress,
                label: tab.name,
                tree: TerminalSplitTree(
                    root: tab.root,
                    focusedPaneID: focused,
                    zoomedPaneID: zoomed
                )
            )],
            paneNames: listing.paneNames,
            paneDirectories: listing.paneDirectories
        ))
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        stop()
        onExit?(.failed(message.isEmpty ? "The Herdr Core connection closed." : message))
    }
}

/// One running `herdr-core connect`, subscribed to every change. Its
/// command runs under `/bin/sh -c`, as
/// `BackendTerminalAttachmentInfo.controlCommand` builds it.
@MainActor
final class HerdrCoreEventStream: HerdrCoreEventFollowing {
    var onChange: (() -> Void)?
    var onExit: ((String) -> Void)?

    /// Events that can add, remove, or rename a pane. Status, size, and
    /// foreground-program events arrive often and move nothing.
    private static let changes: Set = [
        "doc", "created", "restarted", "finished", "removed", "labels", "title",
    ]

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private var lineBuffer = Data()
    private var sawMarker = false
    private var subscribed = false
    private var errorText = Data()
    private var outputClosed = false
    private var errorsClosed = false
    private var exited = false
    private var finished = false

    init(command: String, accountShell: String = AccountCommandRunner.loginShell()) throws {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment
            .merging(["SHELL": accountShell]) { _, account in account }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(data) }
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receiveError(data) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.exited = true
                    self?.finishIfDone()
                }
            }
        }
        try process.run()
        var request = Data(HerdrCoreInventory.eventsRequest.utf8)
        request.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: request)
    }

    func stop() {
        guard !finished else { return }
        finished = true
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func receive(_ data: Data) {
        guard !finished else { return }
        guard !data.isEmpty else {
            outputClosed = true
            finishIfDone()
            return
        }
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 0x0A) {
            let line = Data(lineBuffer[lineBuffer.startIndex ..< newline])
            lineBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard sawMarker else {
                sawMarker = line.elementsEqual(HerdrCoreInventory.eventsMarker.utf8)
                continue
            }
            handle(line)
            if finished {
                return
            }
        }
    }

    private func handle(_ line: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: line) else {
            return fail("Cannot update this Herdr tab.")
        }
        if !subscribed {
            guard message.error == nil, message.result != nil else {
                return fail(message.error?.message ?? "Herdr refused tab updates.")
            }
            subscribed = true
            // A listing that started first could miss earlier changes.
            onChange?()
            return
        }
        switch message.method {
        case "missed":
            onChange?()
        case "event" where message.params?.type.map(Self.changes.contains) == true:
            onChange?()
        default:
            break
        }
    }

    private func receiveError(_ data: Data) {
        guard !data.isEmpty else {
            errorsClosed = true
            finishIfDone()
            return
        }
        if errorText.count < 4096 {
            errorText.append(data.prefix(4096 - errorText.count))
        }
    }

    /// Every pipe is read to its end first, so the exit reports what the
    /// core last wrote.
    private func finishIfDone() {
        guard outputClosed, errorsClosed, exited, !finished else { return }
        let message = String(decoding: errorText, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fail(message)
    }

    private func fail(_ message: String) {
        stop()
        onExit?(message)
    }

    private struct Message: Decodable {
        var method: String?
        var params: Params?
        var result: AnyResult?
        var error: RPCError?

        struct Params: Decodable {
            var type: String?
        }

        struct RPCError: Decodable {
            var message: String
        }

        /// Present when the reply succeeded; its content does not matter.
        struct AnyResult: Decodable {
            init(from _: any Decoder) {}
        }
    }
}
