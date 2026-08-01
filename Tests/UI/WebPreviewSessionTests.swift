import AppKit
import Foundation
@testable import GhosthubUI
import Testing
import WebKit

@MainActor
@Suite("Web preview session store")
struct WebPreviewStoreTests {
    @Test("sessions are stable per worktree and isolate website data")
    func sessionsAreStableAndIsolated() {
        let store = WebPreviewStore()
        let firstContext = makeWebPreviewContext(name: "first")
        let secondContext = makeWebPreviewContext(name: "second")

        let first = store.session(for: firstContext)
        let firstAgain = store.session(for: firstContext)
        let second = store.session(for: secondContext)

        #expect(first === firstAgain)
        #expect(first !== second)
        #expect(first.websiteDataStore !== second.websiteDataStore)
        #expect(!first.websiteDataStore.isPersistent)
        #expect(!second.websiteDataStore.isPersistent)
    }
}

@MainActor
@Suite("Web preview session lifecycle")
struct WebPreviewSessionLifecycleTests {
    @Test("page close and teardown release the matching auxiliary windows")
    func auxiliaryWindowsCloseByWebViewIdentity() {
        let session = WebPreviewSession(
            context: makeWebPreviewContext(name: "lifecycle")
        )
        let firstWebView = makeAuxiliaryWebView(for: session)
        let secondWebView = makeAuxiliaryWebView(for: session)
        let firstWindow = CloseTrackingWindow()
        let secondWindow = CloseTrackingWindow()
        let secondController = NSWindowController(window: secondWindow)
        weak var releasedFirstController: NSWindowController?

        autoreleasepool {
            var firstController: NSWindowController? = NSWindowController(
                window: firstWindow
            )
            releasedFirstController = firstController

            session.trackAuxiliaryWindow(
                firstController!,
                for: firstWebView
            )
            session.trackAuxiliaryWindow(
                secondController,
                for: secondWebView
            )
            firstController = nil

            session.webViewDidClose(firstWebView)

            #expect(firstWindow.closeCallCount == 1)
            #expect(secondWindow.closeCallCount == 0)
        }
        #expect(releasedFirstController == nil)

        session.tearDown()

        #expect(firstWindow.closeCallCount == 1)
        #expect(secondWindow.closeCallCount == 1)
    }

    @Test("pruning a context releases its complete session")
    func pruningReleasesSession() {
        let store = WebPreviewStore()
        let context = makeWebPreviewContext(name: "removed")
        var session: WebPreviewSession? = store.session(for: context)
        weak let releasedSession = session

        session = nil
        store.retainSessions(withIDs: [])

        #expect(releasedSession == nil)
    }

    @Test("retry targets a failed navigation instead of the previous page")
    func retryTargetsFailedNavigation() {
        let previousURL = URL(string: "https://example.com/previous")!
        let failedURL = URL(string: "http://localhost:3000/failed")!
        var recovery = WebPreviewNavigationRecovery()

        recovery.begin(previousURL)
        recovery.finish()
        recovery.begin(failedURL)
        recovery.fail(fallbackURL: previousURL)

        #expect(recovery.retryURL == failedURL)
    }

    @Test("download replacement preserves the original until success")
    func downloadReplacementIsAtomic() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("artifact.zip")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("old".utf8).write(to: destination)

        let prepared = try WebPreviewDownloadDestination.prepare(destination)

        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: prepared.temporaryURL.path
            )
        )

        try Data("new".utf8).write(to: prepared.temporaryURL)
        try prepared.finish()

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: prepared.temporaryURL.path
            )
        )
    }

    @Test("failed download removes only its temporary file")
    func failedDownloadPreservesOriginal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("artifact.zip")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("old".utf8).write(to: destination)
        let prepared = try WebPreviewDownloadDestination.prepare(destination)
        try Data("partial".utf8).write(to: prepared.temporaryURL)

        #expect(prepared.cancel() == nil)

        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        #expect(
            !FileManager.default.fileExists(
                atPath: prepared.temporaryURL.path
            )
        )
    }
}

@MainActor
private func makeAuxiliaryWebView(
    for session: WebPreviewSession
) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = session.websiteDataStore
    return WKWebView(frame: .zero, configuration: configuration)
}

private func makeWebPreviewContext(name: String) -> WebPreviewContext {
    WebPreviewContext(
        id: name,
        worktreeID: UUID(),
        worktreeName: name
    )
}

@MainActor
private final class CloseTrackingWindow: NSWindow {
    private(set) var closeCallCount = 0

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    override func close() {
        closeCallCount += 1
        super.close()
    }
}
