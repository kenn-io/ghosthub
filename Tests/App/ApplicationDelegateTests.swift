#if canImport(AppKit)
import AppKit
import GhosthubUI
import GhosthubWorkspace
import XCTest
import UserNotifications
@testable import GhosthubApp
@testable import GhosthubTerminal

// MARK: - Test Fixtures

extension XCTestCase {
    /// Creates a temporary `.app` bundle with a minimal Info.plist.
    /// Automatically cleaned up via `addTeardownBlock`.
    func makeMockAppBundle() throws -> Bundle {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        )
        let plistURL = contentsURL.appendingPathComponent(
            "Info.plist",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: contentsURL,
            withIntermediateDirectories: true
        )
        let plist = """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \
        \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
        <plist version=\"1.0\">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.ghosthub.tests</string>
        </dict>
        </plist>
        """
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: bundleURL)
        }
        return Bundle(url: bundleURL)!
    }

    /// Creates a temporary directory that is automatically cleaned up
    /// via `addTeardownBlock`.
    func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Creates mock system and library sound directories with a dummy
    /// `Glass.aiff` file. The library directory uses a non-existent
    /// subdirectory so tests can verify directory creation.
    func makeMockSoundsEnvironment()
        throws -> (systemDir: URL, libraryDir: URL) {
        let systemDir = try makeTemporaryDirectory()
        let libraryDir = try makeTemporaryDirectory()
            .appendingPathComponent("NotYetCreated", isDirectory: true)
        try "test".write(
            to: systemDir.appendingPathComponent("Glass.aiff"),
            atomically: true,
            encoding: .utf8
        )
        return (systemDir, libraryDir)
    }
}

extension NotificationsConfiguration {
    static func testMake(
        idleThresholdSeconds: Int = 30,
        showMacOSNotifications: Bool = true,
        showDockBadge: Bool = true,
        attentionSound: WorkspaceNotificationSound = .systemDefault,
        presetOverrides: [String: PresetNotificationConfiguration] = [:]
    ) -> NotificationsConfiguration {
        NotificationsConfiguration(
            idleThresholdSeconds: idleThresholdSeconds,
            showMacOSNotifications: showMacOSNotifications,
            showDockBadge: showDockBadge,
            attentionSound: attentionSound,
            presetOverrides: presetOverrides
        )
    }
}

extension ApplicationDelegate {
    /// Creates a delegate pre-configured for testing.
    static func forTesting(
        needsConfirmQuit: Bool = true,
        confirmTerminationResult: Bool = true
    ) -> ApplicationDelegate {
        let delegate = ApplicationDelegate()
        delegate.needsConfirmQuit = { needsConfirmQuit }
        delegate.requestTerminationConfirmation = { completion in
            completion(confirmTerminationResult)
        }
        delegate.shutdownForTermination = {}
        delegate.replyToApplicationShouldTerminate = { _ in }
        return delegate
    }
}

// MARK: - Tests

@MainActor
final class ApplicationDelegateTests: XCTestCase {
    private final class QuitRequestSource: ApplicationQuitRequestSource {
        var quitRequestHandler: (() -> Void)?

        func requestQuit() {
            quitRequestHandler?()
        }
    }

    private class CloseSpyWindow: NSWindow {
        private(set) var closeCallCount = 0

        override func close() {
            closeCallCount += 1
        }
    }

    private final class HiddenTabBarWindow: CloseSpyWindow {
        override var tabbedWindows: [NSWindow]? { nil }
    }

    func testWindowRestorationFinishedHandlerIsLatched() {
        let delegate = ApplicationDelegate()
        let expectedCount = WorkspaceWindowIdentity.count(
            in: NSApplication.shared.windows
        )
        delegate.applicationDidFinishRestoringWindows(
            Notification(name: NSApplication.didFinishRestoringWindowsNotification)
        )
        var callCount = 0
        var receivedCount: Int?

        delegate.setWindowRestorationFinishedHandler { count in
            callCount += 1
            receivedCount = count
        }
        delegate.applicationDidFinishRestoringWindows(
            Notification(name: NSApplication.didFinishRestoringWindowsNotification)
        )

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(receivedCount, expectedCount)
    }

    private final class NotificationCenterSpy: UserNotificationCentering {
        private(set) var requestAuthorizationCallCount = 0
        private(set) var addedRequests: [UNNotificationRequest] = []
        var nextAuthorizationResult = true

        func requestAuthorization(
            options: UNAuthorizationOptions
        ) async throws -> Bool {
            requestAuthorizationCallCount += 1
            return nextAuthorizationResult
        }

        func add(_ request: UNNotificationRequest) {
            addedRequests.append(request)
        }
    }

    @MainActor
    private final class NotificationCenterFactorySpy {
        private(set) var buildCallCount = 0
        let center = NotificationCenterSpy()

        func makeCenter() -> UserNotificationCentering {
            buildCallCount += 1
            return center
        }
    }

    @MainActor
    private final class SoundPlayerSpy {
        private(set) var playedSounds: [WorkspaceNotificationSound] = []

        func play(_ sound: WorkspaceNotificationSound) {
            playedSounds.append(sound)
        }
    }

    private func makeTestNotificationService(
        config: NotificationsConfiguration = .testMake(),
        bundle: Bundle? = nil,
        center: NotificationCenterSpy = NotificationCenterSpy(),
        soundPlayer: SoundPlayerSpy = SoundPlayerSpy(),
        librarySoundsDir: URL? = nil,
        systemSoundsDir: URL? = nil
    ) throws -> (
        LiveNotificationService, NotificationCenterSpy, SoundPlayerSpy
    ) {
        let resolvedBundle = try bundle ?? makeMockAppBundle()
        let service = LiveNotificationService(
            config: config,
            bundle: resolvedBundle,
            notificationCenter: center,
            librarySoundsDirectoryProvider: librarySoundsDir.map {
                dir in { @Sendable @MainActor in dir }
            } ?? { @Sendable @MainActor in nil },
            systemSoundsDirectory: systemSoundsDir ?? URL(
                fileURLWithPath: "/System/Library/Sounds",
                isDirectory: true
            ),
            soundPlayer: soundPlayer.play
        )
        return (service, center, soundPlayer)
    }

    func testLiveNotificationServiceSkipsAuthorizationOutsideAppBundle() async throws {
        let testBundle = Bundle(for: Self.self)
        XCTAssertFalse(
            LiveNotificationService.supportsUserNotifications(
                bundle: testBundle
            )
        )

        let (service, center, _) = try makeTestNotificationService(
            bundle: testBundle
        )

        await service.requestAuthorization()

        XCTAssertEqual(center.requestAuthorizationCallCount, 0)
    }

    func testLiveNotificationServiceDoesNotConstructDefaultCenterOutsideAppBundle() async {
        let bundle = Bundle(for: Self.self)
        XCTAssertFalse(
            LiveNotificationService.supportsUserNotifications(bundle: bundle)
        )

        let factory = NotificationCenterFactorySpy()
        let service = LiveNotificationService(
            config: .testMake(),
            bundle: bundle,
            notificationCenterProvider: { factory.makeCenter() }
        )

        await service.requestAuthorization()

        XCTAssertEqual(factory.buildCallCount, 0)
    }

    func testLiveNotificationServiceRequestsAuthorizationInsideAppBundle() async throws {
        let (service, center, _) = try makeTestNotificationService()

        await service.requestAuthorization()

        XCTAssertEqual(center.requestAuthorizationCallCount, 1)
    }

    func testLiveNotificationServiceUsesConfiguredCustomAttentionSound() async throws {
        let sounds = try makeMockSoundsEnvironment()
        let (service, center, soundPlayer) = try makeTestNotificationService(
            config: .testMake(attentionSound: .glass),
            librarySoundsDir: sounds.libraryDir,
            systemSoundsDir: sounds.systemDir
        )

        await service.requestAuthorization()
        service.postAgentsNeedAttention(
            worktreeName: "feature/sidebar",
            projectName: "ghosthub"
        )

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertNotNil(center.addedRequests[0].content.sound)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sounds.libraryDir
                    .appendingPathComponent("Ghosthub-Glass.aiff")
                    .path
            )
        )
        XCTAssertTrue(soundPlayer.playedSounds.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sounds.libraryDir.path
            ),
            "Service should create the library sounds directory"
        )
    }

    func testLiveNotificationServiceCreatesLibrarySoundsDirectory() async throws {
        let sounds = try makeMockSoundsEnvironment()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sounds.libraryDir.path
            )
        )

        let (service, _, _) = try makeTestNotificationService(
            config: .testMake(attentionSound: .glass),
            librarySoundsDir: sounds.libraryDir,
            systemSoundsDir: sounds.systemDir
        )

        await service.requestAuthorization()
        service.postAgentsNeedAttention(
            worktreeName: "feature/test",
            projectName: "ghosthub"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sounds.libraryDir.path
            ),
            "Service must create the library sounds directory"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sounds.libraryDir
                    .appendingPathComponent("Ghosthub-Glass.aiff")
                    .path
            )
        )
    }

    func testLiveNotificationServiceUsesDefaultAttentionSoundWhenConfigured() async throws {
        let (service, center, soundPlayer) = try makeTestNotificationService(
            config: .testMake(attentionSound: .systemDefault)
        )

        await service.requestAuthorization()
        service.postAgentsNeedAttention(
            worktreeName: "feature/sidebar",
            projectName: "ghosthub"
        )

        XCTAssertEqual(center.addedRequests.count, 1)
        XCTAssertNotNil(center.addedRequests[0].content.sound)
        XCTAssertTrue(soundPlayer.playedSounds.isEmpty)
    }

    func testApplicationShouldTerminateRepliesAfterAsyncConfirmation() async {
        let delegate = ApplicationDelegate()
        var confirmation: ((Bool) -> Void)?
        let terminationReplied = expectation(description: "termination replied")
        delegate.requestTerminationConfirmation = { callback in
            confirmation = callback
        }
        delegate.shutdownForTermination = {}
        delegate.replyToApplicationShouldTerminate = { confirmed in
            XCTAssertTrue(confirmed)
            terminationReplied.fulfill()
        }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        XCTAssertTrue(delegate.terminationConfirmationPending)

        confirmation?(true)

        await fulfillment(of: [terminationReplied], timeout: 1)
        XCTAssertTrue(delegate.terminationConfirmed)
        XCTAssertFalse(delegate.terminationConfirmationPending)
    }

    func testApplicationShouldTerminateRepliesAfterAsyncCancellation() {
        let delegate = ApplicationDelegate()
        var confirmation: ((Bool) -> Void)?
        var replies: [Bool] = []
        delegate.requestTerminationConfirmation = { callback in
            confirmation = callback
        }
        delegate.replyToApplicationShouldTerminate = { confirmed in
            replies.append(confirmed)
        }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        XCTAssertTrue(delegate.terminationConfirmationPending)
        XCTAssertTrue(replies.isEmpty)

        confirmation?(false)

        XCTAssertEqual(replies, [false])
        XCTAssertFalse(delegate.terminationConfirmed)
        XCTAssertFalse(delegate.terminationConfirmationPending)
    }

    func testUpdaterAuthorizationBypassesExactlyOneTerminationGate() {
        let delegate = ApplicationDelegate.forTesting(
            confirmTerminationResult: false
        )
        delegate.authorizeNextUpdaterTermination()

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        XCTAssertFalse(delegate.terminationConfirmed)
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
    }

    func testClearedUpdaterAuthorizationDoesNotBypassQuit() {
        let delegate = ApplicationDelegate.forTesting(
            confirmTerminationResult: false
        )
        delegate.authorizeNextUpdaterTermination()
        delegate.clearUpdaterTerminationAuthorization()

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
    }

    func testTerminateSkipsConfirmWhenNoActiveSessions() {
        let delegate = ApplicationDelegate.forTesting(
            needsConfirmQuit: false,
            confirmTerminationResult: false
        )
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
    }

    func testTerminationRepliesAfterBoundedSSHShutdown() async {
        let delegate = ApplicationDelegate.forTesting(
            needsConfirmQuit: false
        )
        let cleanupStarted = expectation(description: "cleanup started")
        let terminationReplied = expectation(description: "termination replied")
        let release = AsyncStream<Void>.makeStream()
        delegate.shutdownForTermination = {
            cleanupStarted.fulfill()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        }
        delegate.replyToApplicationShouldTerminate = { shouldTerminate in
            XCTAssertTrue(shouldTerminate)
            terminationReplied.fulfill()
        }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        await fulfillment(of: [cleanupStarted], timeout: 1)
        release.continuation.yield()
        await fulfillment(of: [terminationReplied], timeout: 1)
    }

    func testRequestUserInitiatedTerminationForcesAsyncConfirmationWhenSafe() {
        let delegate = ApplicationDelegate()
        delegate.needsConfirmQuit = { false }

        var confirmationRequests = 0
        var terminated = false
        delegate.requestTerminationConfirmation = { completion in
            confirmationRequests += 1
            completion(true)
        }

        delegate.requestUserInitiatedTermination(forceConfirmation: true) {
            terminated = true
        }

        XCTAssertEqual(confirmationRequests, 1)
        XCTAssertTrue(terminated)
        XCTAssertTrue(delegate.terminationConfirmed)
    }

    func testRequestUserInitiatedTerminationDoesNotTerminateWhenAsyncConfirmationCancels() {
        let delegate = ApplicationDelegate()
        delegate.needsConfirmQuit = { false }

        var terminated = false
        delegate.requestTerminationConfirmation = { completion in
            completion(false)
        }

        delegate.requestUserInitiatedTermination(forceConfirmation: true) {
            terminated = true
        }

        XCTAssertFalse(terminated)
        XCTAssertFalse(delegate.terminationConfirmed)
    }

    func testRepeatedTerminationRequestsSharePendingConfirmation() {
        let delegate = ApplicationDelegate()
        var completion: ((Bool) -> Void)?
        var confirmationRequests = 0
        var terminationRequests = 0
        delegate.requestTerminationConfirmation = { callback in
            confirmationRequests += 1
            completion = callback
        }
        delegate.terminateApplication = {
            terminationRequests += 1
        }

        delegate.requestApplicationTermination()
        delegate.requestApplicationTermination()

        XCTAssertEqual(confirmationRequests, 1)
        XCTAssertEqual(terminationRequests, 0)
        XCTAssertTrue(delegate.terminationConfirmationPending)

        completion?(true)

        XCTAssertEqual(terminationRequests, 1)
        XCTAssertFalse(delegate.terminationConfirmationPending)
        XCTAssertTrue(delegate.terminationConfirmed)
    }

    func testAppKitTerminationJoinsPendingApplicationConfirmation() async {
        let delegate = ApplicationDelegate()
        var completion: ((Bool) -> Void)?
        var terminationRequests = 0
        let terminationReplied = expectation(description: "termination replied")
        delegate.requestTerminationConfirmation = { callback in
            completion = callback
        }
        delegate.terminateApplication = {
            terminationRequests += 1
        }
        delegate.shutdownForTermination = {}
        delegate.replyToApplicationShouldTerminate = { confirmed in
            XCTAssertTrue(confirmed)
            terminationReplied.fulfill()
        }

        delegate.requestApplicationTermination()
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )

        completion?(true)

        await fulfillment(of: [terminationReplied], timeout: 1)
        XCTAssertEqual(terminationRequests, 1)
        XCTAssertTrue(delegate.terminationConfirmed)
        XCTAssertFalse(delegate.terminationConfirmationPending)
    }

    func testJoinedAppKitTerminationCallbacksStartCleanupOnce() async {
        let delegate = ApplicationDelegate()
        var confirmation: ((Bool) -> Void)?
        var cleanupCount = 0
        var replyCount = 0
        let terminationReplied = expectation(description: "termination replied")
        delegate.requestTerminationConfirmation = { callback in
            confirmation = callback
        }
        delegate.shutdownForTermination = {
            cleanupCount += 1
        }
        delegate.replyToApplicationShouldTerminate = { confirmed in
            XCTAssertTrue(confirmed)
            replyCount += 1
            terminationReplied.fulfill()
        }

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateLater
        )

        confirmation?(true)

        await fulfillment(of: [terminationReplied], timeout: 1)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(replyCount, 1)
    }

    func testBoundTerminalQuitUsesAsyncApplicationCoordinator() {
        let source = QuitRequestSource()
        let delegate = ApplicationDelegate()
        var confirmation: ((Bool) -> Void)?
        var confirmationRequests = 0
        var terminationRequests = 0
        delegate.requestTerminationConfirmation = { callback in
            confirmationRequests += 1
            confirmation = callback
        }
        delegate.terminateApplication = {
            terminationRequests += 1
        }
        delegate.bindQuitRequests(from: source)

        source.requestQuit()

        XCTAssertEqual(confirmationRequests, 1)
        XCTAssertEqual(terminationRequests, 0)

        confirmation?(true)

        XCTAssertEqual(terminationRequests, 1)
        XCTAssertTrue(delegate.terminationConfirmed)
    }

    func testApplicationDoesNotTerminateAfterLastWindowCloses() {
        let delegate = ApplicationDelegate.forTesting()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(
                NSApplication.shared
            )
        )
    }

    func testApplicationDisablesAutomaticWindowTabbing() {
        let previousValue = NSWindow.allowsAutomaticWindowTabbing
        defer {
            NSWindow.allowsAutomaticWindowTabbing = previousValue
        }
        NSWindow.allowsAutomaticWindowTabbing = true
        let delegate = ApplicationDelegate()

        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    func testAdoptedWorkspaceTabRestoresParentFrameAfterHostingResize() async {
        let delegate = ApplicationDelegate.forTesting()
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let visibleFrame = NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        parent.setFrame(
            NSRect(
                x: visibleFrame.minX + 40,
                y: visibleFrame.minY + 40,
                width: min(1200, visibleFrame.width - 80),
                height: min(760, visibleFrame.height - 80)
            ),
            display: false
        )
        parent.tabbingIdentifier = WorkspaceWindowIdentity.tabbingIdentifier
        let expectedFrame = parent.frame
        var requestID: UUID?
        delegate.openWorkspaceWindow = { state in
            requestID = state.windowID
        }
        delegate.requestNewWorkspaceTab(from: parent)
        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        child.tabbingIdentifier = WorkspaceWindowIdentity.tabbingIdentifier

        delegate.adoptWorkspaceWindowAsTabIfRequested(
            child,
            requestID: requestID
        )
        child.setFrame(
            NSRect(x: 80, y: 120, width: 224, height: 200),
            display: false
        )
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }

        XCTAssertEqual(parent.frame, expectedFrame)
        XCTAssertEqual(child.frame, expectedFrame)
    }

    func testWorkspaceTabGroupOpensSequentiallyInProjectOrder() async {
        let delegate = ApplicationDelegate.forTesting()
        let firstState = WorkspaceWindowState.fresh()
        let secondState = WorkspaceWindowState.fresh()
        let thirdState = WorkspaceWindowState.fresh()
        var openedStates: [WorkspaceWindowState] = []
        delegate.openWorkspaceWindow = { state in
            openedStates.append(state)
        }

        delegate.requestWorkspaceTabGroup([
            firstState,
            secondState,
            thirdState,
        ], launchIntent: .openWorktree)
        XCTAssertEqual(openedStates.map(\.windowID), [firstState.windowID])

        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        firstWindow.tabbingIdentifier =
            WorkspaceWindowIdentity.tabbingIdentifier
        delegate.adoptWorkspaceWindowAsTabIfRequested(
            firstWindow,
            requestID: firstState.windowID
        )
        await Task.yield()

        XCTAssertEqual(openedStates.map(\.windowID), [
            firstState.windowID,
            secondState.windowID,
        ])

        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        secondWindow.tabbingIdentifier =
            WorkspaceWindowIdentity.tabbingIdentifier
        delegate.adoptWorkspaceWindowAsTabIfRequested(
            secondWindow,
            requestID: secondState.windowID
        )
        await Task.yield()

        XCTAssertEqual(openedStates.map(\.windowID), [
            firstState.windowID,
            secondState.windowID,
            thirdState.windowID,
        ])
        let thirdWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        thirdWindow.tabbingIdentifier =
            WorkspaceWindowIdentity.tabbingIdentifier
        delegate.adoptWorkspaceWindowAsTabIfRequested(
            thirdWindow,
            requestID: thirdState.windowID
        )

        XCTAssertEqual(
            firstWindow.tabGroup?.windows.map(ObjectIdentifier.init),
            [firstWindow, secondWindow, thirdWindow].map(ObjectIdentifier.init)
        )
        XCTAssertTrue(
            WorkspaceWindowIdentity.group(containing: firstWindow)
                .contains(where: { $0 === secondWindow })
        )
    }

    func testClosingRetainedTabParentCancelsRemainingGroup() async {
        let delegate = ApplicationDelegate.forTesting()
        let firstState = WorkspaceWindowState.fresh()
        let secondState = WorkspaceWindowState.fresh()
        let thirdState = WorkspaceWindowState.fresh()
        var openedStates: [WorkspaceWindowState] = []
        delegate.openWorkspaceWindow = { state in
            openedStates.append(state)
        }
        delegate.requestWorkspaceTabGroup([
            firstState,
            secondState,
            thirdState,
        ], launchIntent: .openWorktree)
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        firstWindow.tabbingIdentifier =
            WorkspaceWindowIdentity.tabbingIdentifier
        delegate.adoptWorkspaceWindowAsTabIfRequested(
            firstWindow,
            requestID: firstState.windowID
        )
        await Task.yield()
        XCTAssertEqual(openedStates.map(\.windowID), [
            firstState.windowID,
            secondState.windowID,
        ])

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: firstWindow
        )
        let secondWindow = CloseSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        secondWindow.tabbingIdentifier =
            WorkspaceWindowIdentity.tabbingIdentifier
        delegate.adoptWorkspaceWindowAsTabIfRequested(
            secondWindow,
            requestID: secondState.windowID
        )
        await Task.yield()

        XCTAssertEqual(secondWindow.closeCallCount, 1)
        XCTAssertEqual(openedStates.map(\.windowID), [
            firstState.windowID,
            secondState.windowID,
        ])
    }

    func testLastWindowClosesWithoutRequestingTermination() {
        let delegate = ApplicationDelegate.forTesting(
            confirmTerminationResult: true
        )
        let window = CloseSpyWindow()
        var terminationRequests = 0
        delegate.terminateApplication = {
            terminationRequests += 1
        }

        delegate.requestWorkspaceWindowClose(window)

        XCTAssertEqual(window.closeCallCount, 1)
        XCTAssertEqual(terminationRequests, 0)
        XCTAssertFalse(delegate.terminationConfirmed)
    }

    func testClosingHiddenTabBarGroupDoesNotRequestTermination() {
        let delegate = ApplicationDelegate.forTesting()
        let window = HiddenTabBarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let tab = CloseSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.addTabbedWindow(tab, ordered: .above)
        var terminationRequests = 0
        delegate.terminateApplication = {
            terminationRequests += 1
        }

        delegate.requestWorkspaceWindowClose(window)

        XCTAssertEqual(window.closeCallCount, 1)
        XCTAssertEqual(tab.closeCallCount, 1)
        XCTAssertEqual(terminationRequests, 0)
        XCTAssertFalse(delegate.terminationConfirmed)
    }

    func testTrafficLightClosesHiddenTabBarGroupWithoutTerminating()
        throws {
        let delegate = ApplicationDelegate.forTesting()
        let window = HiddenTabBarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let tab = CloseSpyWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.addTabbedWindow(tab, ordered: .above)
        var terminationRequests = 0
        delegate.terminateApplication = {
            terminationRequests += 1
        }
        let controller = CompactWorkspaceTitlebarController(
            applicationDelegate: delegate
        )
        controller.install(on: window)
        let closeButton = try XCTUnwrap(
            window.standardWindowButton(.closeButton)
        )

        closeButton.performClick(nil)

        XCTAssertEqual(window.closeCallCount, 1)
        XCTAssertEqual(tab.closeCallCount, 1)
        XCTAssertEqual(terminationRequests, 0)
        XCTAssertFalse(delegate.terminationConfirmed)
    }

    func testTabCloseClosesOnlySelectedWorkspace() {
        let delegate = ApplicationDelegate.forTesting()
        let window = CloseSpyWindow()
        let sibling = CloseSpyWindow()

        delegate.requestWorkspaceTabClose(window)

        XCTAssertEqual(window.closeCallCount, 1)
        XCTAssertEqual(sibling.closeCallCount, 0)
        XCTAssertFalse(delegate.terminationConfirmed)
    }

    func testResolvedAppAppearanceNamesMatchPreference() {
        XCTAssertNil(
            AppAppearance.resolvedNSAppearanceName(for: .system)
        )
        XCTAssertEqual(
            AppAppearance.resolvedNSAppearanceName(for: .light),
            .aqua
        )
        XCTAssertEqual(
            AppAppearance.resolvedNSAppearanceName(for: .dark),
            .darkAqua
        )
    }

    func testWorkspaceWindowChromeUsesCompactTitleSurface() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.toolbar = NSToolbar(identifier: "test-toolbar")
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 960, height: 640)

        WorkspaceWindowChrome.apply(to: window)
        WorkspaceWindowChrome.apply(to: window)

        XCTAssertNil(window.toolbar, "A toolbar would add a second chrome row")
        XCTAssertTrue(
            window.titlebarAppearsTransparent,
            "The uniform workspace surface should continue into the titlebar"
        )
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(
            CompactWorkspaceTitlebarController.showsTitle(tabCount: 1)
        )
        XCTAssertEqual(
            window.contentMinSize,
            .zero,
            "A terminal window must not inherit a workspace-sized minimum"
        )

        let titlebar = try XCTUnwrap(
            window.standardWindowButton(.closeButton)?.superview
        )
        XCTAssertTrue(
            titlebar.wantsLayer,
            "The compact titlebar must own its uniform color layer"
        )
        XCTAssertNotNil(
            titlebar.layer?.backgroundColor,
            "The titlebar color cannot depend on underlying terminal content"
        )
    }

    func testTabbedWorkspaceWindowChromeHidesRedundantTitle() {
        XCTAssertFalse(
            CompactWorkspaceTitlebarController.showsTitle(tabCount: 2)
        )
    }

    func testWorkspaceTitleClearsTheVisibleSidebar() {
        XCTAssertEqual(
            CompactWorkspaceTitlebarController.titleLeadingOffset(
                isSidebarVisible: true,
                sidebarWidth: 360
            ),
            372
        )
        XCTAssertEqual(
            CompactWorkspaceTitlebarController.titleLeadingOffset(
                isSidebarVisible: false,
                sidebarWidth: 360
            ),
            120
        )
    }

    func testWindowCloseDelegateClosesWithoutTerminating() throws {
        let delegate = ApplicationDelegate.forTesting()
        var terminationRequests = 0
        delegate.terminateApplication = {
            terminationRequests += 1
        }
        let window = CloseSpyWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 800,
                height: 600
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = CompactWorkspaceTitlebarController(
            applicationDelegate: delegate
        )
        controller.install(on: window)
        let shouldClose = try XCTUnwrap(
            window.delegate?.windowShouldClose?(window)
        )
        XCTAssertFalse(shouldClose)
        XCTAssertEqual(window.closeCallCount, 1)
        XCTAssertEqual(terminationRequests, 0)
    }

    func testWindowCloseDelegateForwardsOtherCallbacks() throws {
        final class ForwardingDelegate: NSObject, NSWindowDelegate {
            var resizeCount = 0

            func windowDidResize(_ notification: Notification) {
                resizeCount += 1
            }
        }

        let appDelegate = ApplicationDelegate.forTesting()
        let forwardingDelegate = ForwardingDelegate()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = forwardingDelegate
        let controller = CompactWorkspaceTitlebarController(
            applicationDelegate: appDelegate
        )

        controller.install(on: window)

        let installedDelegate = try XCTUnwrap(
            window.delegate as? NSObject
        )
        let selector = #selector(
            NSWindowDelegate.windowDidResize(_:)
        )
        XCTAssertTrue(installedDelegate.responds(to: selector))
        _ = installedDelegate.perform(
            selector,
            with: Notification(
                name: NSWindow.didResizeNotification,
                object: window
            )
        )
        XCTAssertEqual(forwardingDelegate.resizeCount, 1)
    }

    func testCompactTitlebarUsesDisplayName() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = CompactWorkspaceTitlebarController()
        controller.update(
            isSidebarVisible: true,
            canCreateWorktree: true,
            sessionTitle: SessionTitlebarPresentation(
                displayName: "ghosthub / feature/api",
                hostname: "studio-mac",
                icon: .tmuxSession
            ),
            onToggleSidebar: {},
            onQuickLaunch: {},
            onSettings: {},
            onNewWorktree: {}
        )

        controller.install(on: window)

        XCTAssertNil(window.toolbar)
        XCTAssertEqual(
            window.title,
            "ghosthub / feature/api · studio-mac"
        )
        XCTAssertEqual(window.titleVisibility, .hidden)

        controller.update(
            isSidebarVisible: true,
            canCreateWorktree: true,
            sessionTitle: SessionTitlebarPresentation(
                displayName: "ghosthub / feature/api",
                hostname: "studio-mac",
                icon: .tmuxSession
            ),
            customTitle: "Review logs",
            onToggleSidebar: {},
            onQuickLaunch: {},
            onSettings: {},
            onNewWorktree: {}
        )
        controller.install(on: window)

        XCTAssertEqual(window.title, "Review logs")
    }

}
#endif
