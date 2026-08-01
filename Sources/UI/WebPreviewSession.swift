import AppKit
@preconcurrency import Combine
import Foundation
import WebKit

@MainActor
public final class WebPreviewStore: ObservableObject {
    private var sessions: [WebPreviewContext.ID: WebPreviewSession] = [:]

    public init() {}

    public func session(
        for context: WebPreviewContext
    ) -> WebPreviewSession {
        if let session = sessions[context.id] {
            return session
        }
        let session = WebPreviewSession(context: context)
        sessions[context.id] = session
        return session
    }

    public func retainSessions(
        withIDs ids: Set<WebPreviewContext.ID>
    ) {
        for id in Set(sessions.keys).subtracting(ids) {
            sessions.removeValue(forKey: id)?.tearDown()
        }
    }

    public func tearDown() {
        let retainedSessions = Array(sessions.values)
        sessions.removeAll()
        for session in retainedSessions {
            session.tearDown()
        }
    }
}

@MainActor
public final class WebPreviewSession: NSObject, ObservableObject {
    public let context: WebPreviewContext
    let websiteDataStore: WKWebsiteDataStore
    public let webView: WKWebView

    @Published public var addressText = ""
    @Published public private(set) var canGoBack = false
    @Published public private(set) var canGoForward = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var estimatedProgress = 0.0
    @Published public private(set) var errorMessage: String?

    private var observations: [NSKeyValueObservation] = []
    private var auxiliaryWindows:
        [ObjectIdentifier: NSWindowController] = [:]
    private var isTornDown = false

    public init(context: WebPreviewContext) {
        self.context = context
        websiteDataStore = .nonPersistent()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeNavigationState()
    }

    public func submitAddress() {
        do {
            let url = try WebPreviewAddress.parse(addressText)
            errorMessage = nil
            webView.load(URLRequest(url: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    public func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    public func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
        } else if webView.url != nil {
            webView.reload()
        } else {
            submitAddress()
        }
    }

    public func retry() {
        if webView.url != nil {
            errorMessage = nil
            webView.reload()
        } else {
            submitAddress()
        }
    }

    public func openExternally() {
        guard let url = webView.url else { return }
        NSWorkspace.shared.open(url)
    }

    public func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true

        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil

        let controllers = Array(auxiliaryWindows.values)
        auxiliaryWindows.removeAll()
        for controller in controllers {
            closeAuxiliaryWindow(controller)
        }
    }

    func trackAuxiliaryWindow(
        _ controller: NSWindowController,
        for webView: WKWebView
    ) {
        controller.window?.delegate = self
        auxiliaryWindows[ObjectIdentifier(webView)] = controller
    }

    private func observeNavigationState() {
        observations = [
            webView.observe(
                \.canGoBack,
                options: [.initial, .new]
            ) { [weak self] _, change in
                MainActor.assumeIsolated {
                    self?.canGoBack = change.newValue ?? false
                }
            },
            webView.observe(
                \.canGoForward,
                options: [.initial, .new]
            ) { [weak self] _, change in
                MainActor.assumeIsolated {
                    self?.canGoForward = change.newValue ?? false
                }
            },
            webView.observe(
                \.isLoading,
                options: [.initial, .new]
            ) { [weak self] _, change in
                MainActor.assumeIsolated {
                    self?.isLoading = change.newValue ?? false
                }
            },
            webView.observe(
                \.estimatedProgress,
                options: [.initial, .new]
            ) { [weak self] _, change in
                MainActor.assumeIsolated {
                    self?.estimatedProgress = change.newValue ?? 0
                }
            },
            webView.observe(\.url, options: [.new]) {
                [weak self] _, change in
                MainActor.assumeIsolated {
                    guard let url = change.newValue ?? nil else { return }
                    self?.addressText = url.absoluteString
                }
            },
        ]
    }

    private func recordNavigationError(
        _ error: Error,
        in webView: WKWebView
    ) {
        guard webView === self.webView else { return }
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        errorMessage = nsError.localizedDescription
    }

    private func closeAuxiliaryWindow(
        _ controller: NSWindowController,
        shouldClose: Bool = true
    ) {
        let window = controller.window
        if let auxiliaryWebView = window?.contentView as? WKWebView {
            auxiliaryWebView.stopLoading()
            auxiliaryWebView.navigationDelegate = nil
            auxiliaryWebView.uiDelegate = nil
        }
        window?.contentView = nil
        window?.delegate = nil
        if shouldClose {
            controller.close()
        }
        controller.window = nil
        window?.windowController = nil
    }

    func handleDownloadAuthentication(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    private func presentAlert(
        for webView: WKWebView,
        frame: WKFrameInfo,
        message: String,
        style: NSAlert.Style,
        buttons: [String],
        accessoryView: NSView? = nil,
        completion: @escaping @MainActor @Sendable (
            NSApplication.ModalResponse
        ) -> Void
    ) {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty
            ? "Message from this website"
            : "Message from \(host)"
        alert.informativeText = message
        alert.alertStyle = style
        alert.accessoryView = accessoryView
        buttons.forEach { alert.addButton(withTitle: $0) }

        if let window = webView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

extension WebPreviewSession: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation?
    ) {
        guard webView === self.webView else { return }
        errorMessage = nil
    }

    public func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation?
    ) {
        guard webView === self.webView else { return }
        errorMessage = nil
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation?,
        withError error: Error
    ) {
        recordNavigationError(error, in: webView)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation?,
        withError error: Error
    ) {
        recordNavigationError(error, in: webView)
    }

    public func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }

    public func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        download.delegate = self
    }
}

extension WebPreviewSession: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let auxiliaryWebView = WKWebView(
            frame: .zero,
            configuration: configuration
        )
        auxiliaryWebView.navigationDelegate = self
        auxiliaryWebView.uiDelegate = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = context.worktreeName
        window.contentView = auxiliaryWebView
        let controller = NSWindowController(window: window)
        trackAuxiliaryWindow(controller, for: auxiliaryWebView)
        controller.showWindow(nil)
        return auxiliaryWebView
    }

    public func webViewDidClose(_ webView: WKWebView) {
        guard let controller = auxiliaryWindows.removeValue(
            forKey: ObjectIdentifier(webView)
        ) else {
            return
        }
        closeAuxiliaryWindow(controller)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        presentAlert(
            for: webView,
            frame: frame,
            message: message,
            style: .informational,
            buttons: ["OK"]
        ) { _ in
            completionHandler()
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        presentAlert(
            for: webView,
            frame: frame,
            message: message,
            style: .informational,
            buttons: ["OK", "Cancel"]
        ) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let input = NSTextField(string: defaultText ?? "")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        presentAlert(
            for: webView,
            frame: frame,
            message: prompt,
            style: .informational,
            buttons: ["OK", "Cancel"],
            accessoryView: input
        ) { response in
            completionHandler(
                response == .alertFirstButtonReturn
                    ? input.stringValue
                    : nil
            )
        }
    }

    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (
            WKPermissionDecision
        ) -> Void
    ) {
        decisionHandler(.prompt)
    }
}

extension WebPreviewSession: WKDownloadDelegate {
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFilename
        let finish: @MainActor @Sendable (
            NSApplication.ModalResponse
        ) -> Void = { response in
            completionHandler(response == .OK ? panel.url : nil)
        }

        if let window = download.webView?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    public func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        handleDownloadAuthentication(
            challenge,
            completionHandler: completionHandler
        )
    }
}

extension WebPreviewSession: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = auxiliaryWindows.first(where: {
                  $0.value.window === window
              })
        else {
            return
        }
        let controller = auxiliaryWindows.removeValue(forKey: entry.key)
        if let controller {
            closeAuxiliaryWindow(controller, shouldClose: false)
        }
    }
}
