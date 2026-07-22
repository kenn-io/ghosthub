#if canImport(AppKit)
import AppKit
import GhosthubUI
import GhosthubWorkspace
import XCTest
import UserNotifications
@testable import GhosthubApp

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
        delegate.confirmTermination = { confirmTerminationResult }
        return delegate
    }
}

// MARK: - Tests

@MainActor
final class ApplicationDelegateTests: XCTestCase {
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

    func testApplicationShouldTerminateHonorsConfirmation() {
        let confirmDelegate = ApplicationDelegate.forTesting(
            confirmTerminationResult: true
        )
        XCTAssertEqual(
            confirmDelegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )

        let cancelDelegate = ApplicationDelegate.forTesting(
            confirmTerminationResult: false
        )
        XCTAssertEqual(
            cancelDelegate.applicationShouldTerminate(NSApplication.shared),
            .terminateCancel
        )
    }

    func testTerminateSkipsConfirmWhenNoActiveSessions() {
        let delegate = ApplicationDelegate.forTesting(
            needsConfirmQuit: false,
            confirmTerminationResult: false
        )
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )
    }

    func testPrepareUserInitiatedTerminationHonorsConfirmation() {
        let delegate = ApplicationDelegate()

        delegate.confirmTermination = { false }
        XCTAssertFalse(delegate.prepareUserInitiatedTermination())
        XCTAssertFalse(delegate.terminationConfirmed)

        delegate.confirmTermination = { true }
        XCTAssertTrue(delegate.prepareUserInitiatedTermination())
        XCTAssertTrue(delegate.terminationConfirmed)
    }

    func testPrepareUserInitiatedTerminationSkipsPromptWhenSafe() {
        let delegate = ApplicationDelegate()
        delegate.needsConfirmQuit = { false }

        var confirmCalled = false
        delegate.confirmTermination = {
            confirmCalled = true
            return false
        }

        XCTAssertTrue(delegate.prepareUserInitiatedTermination())
        XCTAssertFalse(confirmCalled)
        XCTAssertTrue(delegate.terminationConfirmed)
    }

    func testPrepareUserInitiatedTerminationCanForceConfirmationWhenSafe() {
        let delegate = ApplicationDelegate()
        delegate.needsConfirmQuit = { false }

        var confirmCallCount = 0
        delegate.confirmTermination = {
            confirmCallCount += 1
            return true
        }

        XCTAssertTrue(
            delegate.prepareUserInitiatedTermination(forceConfirmation: true)
        )
        XCTAssertEqual(confirmCallCount, 1)
        XCTAssertTrue(delegate.terminationConfirmed)
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

    func testApplicationShouldTerminateAfterLastWindowClosed() {
        let delegate = ApplicationDelegate.forTesting()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(
                NSApplication.shared
            )
        )
    }

    func testWindowShouldCloseShowsConfirmationBeforeClosing() {
        let delegate = ApplicationDelegate()
        let window = NSWindow()

        delegate.confirmTermination = { false }
        XCTAssertFalse(delegate.windowShouldClose(window))
        XCTAssertFalse(delegate.terminationConfirmed)

        delegate.confirmTermination = { true }
        XCTAssertTrue(delegate.windowShouldClose(window))
        XCTAssertTrue(delegate.terminationConfirmed)

        // After confirmation, termination proceeds without
        // a second dialog.
        XCTAssertTrue(
            delegate.applicationShouldTerminateAfterLastWindowClosed(
                NSApplication.shared
            )
        )
        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )
    }

    func testWindowCloseSkipsConfirmWhenNoActiveSessions() {
        let delegate = ApplicationDelegate()
        let window = NSWindow()
        delegate.needsConfirmQuit = { false }

        var confirmCalled = false
        delegate.confirmTermination = {
            confirmCalled = true
            return false
        }

        XCTAssertTrue(delegate.windowShouldClose(window))
        XCTAssertFalse(confirmCalled)
        XCTAssertTrue(delegate.terminationConfirmed)
    }

    func testClosingNonLastWindowDoesNotArmTermination() {
        let delegate = ApplicationDelegate.forTesting(
            confirmTerminationResult: true
        )

        let windowA = NSWindow()
        let windowB = NSWindow()
        windowA.delegate = delegate
        windowB.delegate = delegate

        // Make both windows part of the app's window list
        windowA.orderBack(nil)
        windowB.orderBack(nil)

        // Close windowA — windowB is still managed by delegate
        let shouldClose = delegate.windowShouldClose(windowA)
        XCTAssertTrue(
            shouldClose,
            "Non-last window should be allowed to close"
        )
        XCTAssertFalse(
            delegate.terminationConfirmed,
            "terminationConfirmed must not be set when other managed windows remain"
        )
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

    func testWorkspaceWindowChromeKeepsOneThinTitlebarSurface() throws {
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

    func testCompactTitlebarInstallsActiveSessionIdentityWithoutToolbar() throws {
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
                sessionName: "docbank",
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
        XCTAssertEqual(window.title, "docbank · studio-mac")
        let titlebar = try XCTUnwrap(
            window.standardWindowButton(.closeButton)?.superview
        )
        let titleHost = try XCTUnwrap(
            titlebar.subviews.first {
                $0.identifier?.rawValue == "GhosthubCompactSessionTitle"
            }
        )
        XCTAssertTrue(titleHost.mouseDownCanMoveWindow)
    }

    func testQuitPolicyRequiresConfirmationWhenRuntimeRequestsIt() {
        XCTAssertTrue(
            QuitPolicy.needsConfirmation(
                runtimeNeedsConfirmQuit: true,
                openTerminalSurfaceCount: 0
            )
        )
    }

    func testQuitPolicyRequiresConfirmationWhenTerminalSurfacesRemainOpen() {
        XCTAssertTrue(
            QuitPolicy.needsConfirmation(
                runtimeNeedsConfirmQuit: false,
                openTerminalSurfaceCount: 2
            )
        )
    }

    func testQuitPolicyAlwaysRequiresConfirmation() {
        XCTAssertTrue(
            QuitPolicy.needsConfirmation(
                runtimeNeedsConfirmQuit: false,
                openTerminalSurfaceCount: 0
            )
        )
    }
}
#endif
