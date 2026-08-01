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

    @Test("download authentication keeps WebKit default handling")
    func downloadAuthenticationUsesDefaultHandling() {
        let session = WebPreviewSession(
            context: makeWebPreviewContext(name: "download")
        )
        let sender = AuthenticationChallengeSender()
        let challenge = URLAuthenticationChallenge(
            protectionSpace: URLProtectionSpace(
                host: "localhost",
                port: 443,
                protocol: "https",
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            ),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        var capturedDisposition: URLSession.AuthChallengeDisposition?
        var capturedCredential: URLCredential?
        let _: any WKDownloadDelegate = session

        session.handleDownloadAuthentication(challenge) {
            disposition, credential in
            capturedDisposition = disposition
            capturedCredential = credential
        }

        #expect(capturedDisposition == .performDefaultHandling)
        #expect(capturedCredential == nil)
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

private final class AuthenticationChallengeSender:
    NSObject,
    URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}

    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}

    func cancel(_ challenge: URLAuthenticationChallenge) {}

    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}

    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
