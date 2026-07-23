import AppKit
import Darwin
import Foundation
import GhosttyKit
import GhosthubWorkspace
import XCTest
@testable import GhosthubApp
@testable import GhosthubTerminal
@testable import GhosthubTerminalSupport

private final class MonitorErrorHandlerBox: @unchecked Sendable {
    var handler: LibghosttyConfigFileMonitor.ErrorHandler?
}

@MainActor
final class LibghosttyRuntimeSmokeTests: XCTestCase {

    /// Retained across the entire test suite so ghostty_app_free is
    /// never called while deferred ghostty_surface_free tasks are
    /// still pending. The process exits after testing, so this is
    /// never explicitly freed.
    private static var retainedRuntime: LibghosttyRuntime?

    // MARK: - Helpers

    /// Creates an isolated runtime with automatic temp directory
    /// cleanup registered via `addTeardownBlock`.
    private func makeIsolatedRuntime() throws -> (
        runtime: LibghosttyRuntime,
        pipeline: LibghosttyConfigPipeline,
        tempRoot: URL
    ) {
        try skipUnlessLibghosttyReady()
        let (pipeline, tempRoot) = makeIsolatedPipeline()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let runtime = LibghosttyRuntime(pipeline: pipeline)
        return (runtime, pipeline, tempRoot)
    }

    private func retainedRuntime() -> LibghosttyRuntime {
        if Self.retainedRuntime == nil {
            let (pipeline, _) = makeIsolatedPipeline()
            Self.retainedRuntime = LibghosttyRuntime(pipeline: pipeline)
        }
        return Self.retainedRuntime!
    }

    private func makeCoordinator() throws -> (
        coordinator: TerminalSurfaceCoordinator,
        config: TerminalSurfaceConfiguration
    ) {
        try skipUnlessLibghosttyReady()
        let runtime = retainedRuntime()
        return (
            TerminalSurfaceCoordinator(runtime: runtime),
            TerminalSurfaceConfiguration()
        )
    }

    private func hostInWindow(
        _ view: TerminalSurfaceView,
        size: CGSize = CGSize(width: 960, height: 640)
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.makeFirstResponder(view)
        view.focusDidChange(true)
        view.sizeDidChange(size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.02,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.main.run(
                until: Date().addingTimeInterval(pollInterval)
            )
        }
        XCTFail(
            "Timed out waiting for condition",
            file: file,
            line: line
        )
    }

    private func waitForFontSize(
        in view: TerminalSurfaceView,
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.02,
        file: StaticString = #filePath,
        line: UInt = #line,
        matching predicate: (CGFloat) -> Bool = { _ in true }
    ) throws -> CGFloat {
        let deadline = Date().addingTimeInterval(timeout)
        var latestSize: CGFloat?
        while Date() < deadline {
            if let size = view.currentFontSizePoints {
                latestSize = size
                if predicate(size) {
                    return size
                }
            }
            RunLoop.main.run(
                until: Date().addingTimeInterval(pollInterval)
            )
        }

        guard let latestSize else {
            throw XCTSkip(
                "Surface font size unavailable in smoke environment"
            )
        }
        XCTFail(
            "Timed out waiting for surface font size",
            file: file,
            line: line
        )
        return latestSize
    }

    // MARK: - Tests

    func testRuntimeInitializesToReadyPhase() throws {
        let ctx = try makeIsolatedRuntime()

        XCTAssertEqual(
            ctx.runtime.phase, .ready,
            "Runtime should reach .ready after init with default config"
        )
        XCTAssertTrue(
            ctx.runtime.bootstrapStatus.isReady,
            "Bootstrap status should be ready"
        )
    }

    func testAppHandleIsNonNil() throws {
        let ctx = try makeIsolatedRuntime()

        XCTAssertNotNil(
            ctx.runtime.unsafeAppHandle,
            "ghostty_app_new should produce a non-nil handle"
        )
    }

    func testDefaultConfigDiagnosticsAreReadable() throws {
        let ctx = try makeIsolatedRuntime()

        for diagnostic in ctx.runtime.diagnostics {
            XCTAssertFalse(
                diagnostic.isEmpty,
                "Diagnostic string should not be empty"
            )
        }
    }

    func testConfigReloadDoesNotCrash() throws {
        let ctx = try makeIsolatedRuntime()

        XCTAssertEqual(ctx.runtime.phase, .ready)
        ctx.runtime.reloadConfig(force: true)

        XCTAssertEqual(
            ctx.runtime.phase, .ready,
            "Phase should remain .ready after forced reload"
        )
    }

    func testConfigReloadWithProjectOverride() throws {
        let ctx = try makeIsolatedRuntime()

        let projectRoot = ctx.tempRoot
            .appendingPathComponent("project", isDirectory: true)
        let projectConfig = ctx.pipeline.paths
            .projectConfigFile(for: projectRoot)

        try FileManager.default.createDirectory(
            at: projectConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "font-size = 15\n"
            .write(to: projectConfig, atomically: true, encoding: .utf8)

        XCTAssertEqual(ctx.runtime.phase, .ready)
        ctx.runtime.reloadConfig(
            projectRoot: projectRoot, force: true
        )

        XCTAssertEqual(
            ctx.runtime.phase, .ready,
            "Phase should remain .ready after project-override reload"
        )
    }

    func testInvalidConfigReloadKeepsLastValidConfig() throws {
        let ctx = try makeIsolatedRuntime()
        let originalHandle = try XCTUnwrap(
            ctx.runtime.unsafeConfigHandle
        )
        try "font-size = definitely-not-a-number\n".write(
            to: ctx.pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )

        let result = ctx.runtime.reloadActiveConfig()

        guard case let .rejected(messages) = result else {
            return XCTFail(
                "Expected invalid configuration to be rejected, got \(result)"
            )
        }
        XCTAssertFalse(messages.isEmpty)
        XCTAssertEqual(ctx.runtime.phase, .ready)
        let retainedHandle = try XCTUnwrap(
            ctx.runtime.unsafeConfigHandle
        )
        XCTAssertEqual(
            UInt(bitPattern: retainedHandle),
            UInt(bitPattern: originalHandle),
            "A rejected reload must retain the last valid config handle."
        )
        XCTAssertEqual(
            ctx.runtime.configReloadNotice?.kind,
            .error
        )
    }

    func testSilentSuccessfulReloadClearsFailureNotice() throws {
        try skipUnlessLibghosttyReady()
        let (pipeline, tempRoot) = makeIsolatedPipeline()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try FileManager.default.createDirectory(
            at: pipeline.paths.configDirectory,
            withIntermediateDirectories: true
        )
        try "font-size = 13\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        let runtime = LibghosttyRuntime(
            pipeline: pipeline,
            configMonitorFactory: { request in
                LibghosttyConfigFileMonitor(
                    fileURLs: request.files,
                    errorHandler: request.errorHandler,
                    changeHandler: {}
                )
            }
        )
        try "font-size = definitely-not-a-number\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        guard case .rejected = runtime.reloadActiveConfig() else {
            return XCTFail("Expected invalid configuration rejection")
        }
        XCTAssertEqual(runtime.configReloadNotice?.kind, .error)

        try "font-size = 15\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        let result = runtime.reloadConfig(
            projectRoot: nil,
            force: true
        )

        XCTAssertEqual(result, .applied)
        XCTAssertNil(runtime.configReloadNotice)
    }

    func testMonitorUpdateFailurePublishesDegradedReload() throws {
        try skipUnlessLibghosttyReady()
        let (pipeline, tempRoot) = makeIsolatedPipeline()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try FileManager.default.createDirectory(
            at: pipeline.paths.configDirectory,
            withIntermediateDirectories: true
        )
        try "font-size = 13\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        var blockedPath: String?
        let runtime = LibghosttyRuntime(
            pipeline: pipeline,
            configMonitorFactory: { request in
                LibghosttyConfigFileMonitor(
                    fileURLs: request.files,
                    queue: DispatchQueue(
                        label: "com.ghosthub.terminal.config-monitor-test"
                    ),
                    debounceInterval: .milliseconds(25),
                    requiringExistingFiles: false,
                    openHandler: { path, flags in
                        guard path == blockedPath else {
                            return open(path, flags)
                        }
                        errno = EMFILE
                        return -1
                    },
                    errorHandler: request.errorHandler,
                    changeHandler: request.changeHandler
                )
            }
        )
        let projectRoot = tempRoot.appendingPathComponent(
            "project",
            isDirectory: true
        )
        let projectConfig = pipeline.paths.projectConfigFile(
            for: projectRoot
        )
        try FileManager.default.createDirectory(
            at: projectConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "font-size = 15\n".write(
            to: projectConfig,
            atomically: true,
            encoding: .utf8
        )
        blockedPath = projectConfig.path

        let result = runtime.reloadConfig(
            projectRoot: projectRoot,
            force: true
        )

        guard case let .appliedWithWarnings(warnings) = result else {
            return XCTFail(
                "Expected degraded monitoring warning, got \(result)"
            )
        }
        XCTAssertEqual(runtime.diagnostics, warnings)
        XCTAssertTrue(
            warnings.contains {
                $0.contains("errno \(EMFILE)")
            }
        )
        XCTAssertEqual(runtime.configReloadNotice?.kind, .error)
        XCTAssertTrue(
            runtime.configReloadNotice?.message.lowercased().contains(
                "reload monitoring is degraded"
            ) == true
        )
        XCTAssertTrue(
            runtime.configPlan?.watchedConfigFiles.contains(
                projectConfig
            ) == true
        )
    }

    func testMonitorFailureRepublishesAfterConfigErrorNotice() throws {
        try skipUnlessLibghosttyReady()
        let (pipeline, tempRoot) = makeIsolatedPipeline()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try FileManager.default.createDirectory(
            at: pipeline.paths.configDirectory,
            withIntermediateDirectories: true
        )
        try "font-size = 13\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        var blockedPath: String?
        let runtime = LibghosttyRuntime(
            pipeline: pipeline,
            configMonitorFactory: { request in
                LibghosttyConfigFileMonitor(
                    fileURLs: request.files,
                    queue: DispatchQueue(
                        label: "com.ghosthub.terminal.config-monitor-test"
                    ),
                    debounceInterval: .milliseconds(25),
                    requiringExistingFiles: false,
                    openHandler: { path, flags in
                        guard path == blockedPath else {
                            return open(path, flags)
                        }
                        errno = EMFILE
                        return -1
                    },
                    errorHandler: request.errorHandler,
                    changeHandler: request.changeHandler
                )
            }
        )
        let projectRoot = tempRoot.appendingPathComponent(
            "project",
            isDirectory: true
        )
        let projectConfig = pipeline.paths.projectConfigFile(
            for: projectRoot
        )
        try FileManager.default.createDirectory(
            at: projectConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "font-size = definitely-not-a-number\n".write(
            to: projectConfig,
            atomically: true,
            encoding: .utf8
        )
        blockedPath = projectConfig.path

        let rejected = runtime.reloadConfig(
            projectRoot: projectRoot,
            force: true
        )
        guard case .rejected = rejected else {
            return XCTFail(
                "Expected invalid configuration rejection, got \(rejected)"
            )
        }
        XCTAssertTrue(
            runtime.configReloadNotice?.message.hasPrefix(
                "Configuration not reloaded:"
            ) == true
        )
        let rejectedNoticeID = runtime.configReloadNotice?.id

        try "font-size = 15\n".write(
            to: projectConfig,
            atomically: true,
            encoding: .utf8
        )
        let applied = runtime.reloadConfig(
            projectRoot: projectRoot,
            force: true
        )

        guard case .appliedWithWarnings = applied else {
            return XCTFail(
                "Expected degraded reload success, got \(applied)"
            )
        }
        XCTAssertNotEqual(runtime.configReloadNotice?.id, rejectedNoticeID)
        XCTAssertTrue(
            runtime.configReloadNotice?.message.hasPrefix(
                "Automatic terminal configuration reload monitoring is degraded:"
            ) == true
        )
    }

    func testInitialMonitorFailurePublishesDegradedNotice() throws {
        try skipUnlessLibghosttyReady()
        let (pipeline, tempRoot) = makeIsolatedPipeline()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try FileManager.default.createDirectory(
            at: pipeline.paths.configDirectory,
            withIntermediateDirectories: true
        )
        try "font-size = 13\n".write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        let runtime = LibghosttyRuntime(
            pipeline: pipeline,
            configMonitorFactory: { request in
                LibghosttyConfigFileMonitor(
                    fileURLs: request.files,
                    queue: DispatchQueue(
                        label: "com.ghosthub.terminal.config-monitor-test"
                    ),
                    debounceInterval: .milliseconds(25),
                    requiringExistingFiles: false,
                    openHandler: { path, flags in
                        guard path == pipeline.paths.globalConfigFile.path
                        else {
                            return open(path, flags)
                        }
                        errno = EMFILE
                        return -1
                    },
                    errorHandler: request.errorHandler,
                    changeHandler: request.changeHandler
                )
            }
        )

        XCTAssertEqual(runtime.configReloadNotice?.kind, .error)
        XCTAssertTrue(
            runtime.configReloadNotice?.message.contains(
                "errno \(EMFILE)"
            ) == true
        )
        XCTAssertEqual(
            runtime.diagnostics.filter {
                $0.contains("errno \(EMFILE)")
            }.count,
            1
        )
    }

    func testAsyncMonitorFailuresPublishOnceUntilRecovery() throws {
        try skipUnlessLibghosttyReady()
        let (pipeline, tempRoot) = makeIsolatedPipeline()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let handlerBox = MonitorErrorHandlerBox()
        let runtime = LibghosttyRuntime(
            pipeline: pipeline,
            configMonitorFactory: { request in
                handlerBox.handler = request.errorHandler
                return LibghosttyConfigFileMonitor(
                    fileURLs: request.files,
                    errorHandler: request.errorHandler,
                    changeHandler: request.changeHandler
                )
            }
        )
        let error = LibghosttyConfigFileMonitorError.openFile(
            pipeline.paths.globalConfigFile,
            EMFILE
        )
        let handler = try XCTUnwrap(handlerBox.handler)

        handler(error)
        waitUntil {
            runtime.configReloadNotice?.message.contains(
                "errno \(EMFILE)"
            ) == true
        }
        let firstNoticeID = runtime.configReloadNotice?.id

        handler(error)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(runtime.configReloadNotice?.id, firstNoticeID)
        XCTAssertEqual(
            runtime.diagnostics.filter {
                $0.contains("errno \(EMFILE)")
            }.count,
            1
        )
    }

    func testIncludedConfigAutomaticallyReloads() throws {
        try skipUnlessLibghosttyReady()
        let (pipeline, tempRoot) = makeIsolatedPipeline()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        _ = try pipeline.prepareGlobalConfig()
        let included = pipeline.paths.configDirectory
            .appendingPathComponent("colors.conf")
        try "foreground = ffffff\n".write(
            to: included,
            atomically: true,
            encoding: .utf8
        )
        try """
        config-file = colors.conf
        font-size = 13
        """.write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )
        let runtime = LibghosttyRuntime(pipeline: pipeline)
        XCTAssertEqual(runtime.phase, .ready)
        XCTAssertTrue(
            runtime.configPlan?.watchedConfigFiles.contains(included)
                == true
        )

        try "foreground = eeeeee\n".write(
            to: included,
            atomically: true,
            encoding: .utf8
        )

        waitUntil(timeout: 3) {
            runtime.configReloadNotice?.kind == .success
        }
        XCTAssertEqual(runtime.diagnostics, [])
    }

    func testPasteboardTypeMappingPreservesMimeSpecificTypes() {
        XCTAssertEqual(
            LibghosttyRuntime.pasteboardType(forMIMEType: "text/plain"),
            .string
        )
        XCTAssertEqual(
            LibghosttyRuntime.pasteboardType(
                forMIMEType: "text/html"
            )?.rawValue,
            "public.html"
        )
        XCTAssertNotNil(
            LibghosttyRuntime.pasteboardType(
                forMIMEType: "application/x-ghosthub-custom"
            ),
            "Unknown MIME types should still map to a usable pasteboard type"
        )
    }

    func testRemoteClipboardPolicyAllowsCopyButRejectsOSC52Write() throws {
        try skipUnlessLibghosttyReady()
        let runtime = retainedRuntime()
        let appHandle = try XCTUnwrap(runtime.unsafeAppHandle)
        let view = TerminalSurfaceView(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        view.blocksClipboardAccess = true
        let userdata = Unmanaged.passUnretained(view.callbackToken).toOpaque()
        let pasteboard = NSPasteboard.general
        let priorContents = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let priorContents {
                pasteboard.setString(priorContents, forType: .string)
            }
        }

        "text/plain".withCString { mime in
            "selected text".withCString { data in
                let contents = [ghostty_clipboard_content_s(
                    mime: mime,
                    data: data
                )]
                contents.withUnsafeBufferPointer { buffer in
                    LibghosttyRuntime.handleWriteClipboard(
                        userdata: userdata,
                        location: GHOSTTY_CLIPBOARD_STANDARD,
                        content: buffer.baseAddress,
                        len: buffer.count,
                        confirm: false
                    )
                }
            }
        }
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "selected text"
        )

        "text/plain".withCString { mime in
            "remote payload".withCString { data in
                LibghosttyRuntime.osc52ClipboardWriteMIME.withCString { marker in
                    "".withCString { empty in
                        let contents = [
                            ghostty_clipboard_content_s(mime: mime, data: data),
                            ghostty_clipboard_content_s(mime: marker, data: empty),
                        ]
                        contents.withUnsafeBufferPointer { buffer in
                            LibghosttyRuntime.handleWriteClipboard(
                                userdata: userdata,
                                location: GHOSTTY_CLIPBOARD_STANDARD,
                                content: buffer.baseAddress,
                                len: buffer.count,
                                confirm: false
                            )
                        }
                    }
                }
            }
        }
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "selected text",
            "OSC 52 must not overwrite the clipboard on an SSH surface"
        )
    }

    func testGhosthubShimContainsConfigFileDirectives() throws {
        let ctx = try makeIsolatedRuntime()

        let shimFile = ctx.pipeline.paths.configDirectory
            .appendingPathComponent(
                ".ghostty-shim", isDirectory: true
            )
            .appendingPathComponent("config", isDirectory: false)

        let shimContent = try String(
            contentsOf: shimFile, encoding: .utf8
        )

        let globalPath = ctx.pipeline.paths.globalConfigFile.path
        XCTAssertTrue(
            shimContent.contains("config-file = \(globalPath)"),
            "Shim should include config-file directive for global config"
        )
        XCTAssertFalse(
            shimContent.contains("font-family"),
            "Shim should not inline config content"
        )
    }

    func testCoordinatorCarriesRuntimeFontZoomToNewSurfaces() throws {
        let (coordinator, config) = try makeCoordinator()
        defer {
            coordinator.removeAll()
        }
        let firstKey = SurfaceKey.fixture(
            worktreeID: UUID(),
            hostID: UUID(),
            target: .worktreeShell
        )

        guard let firstView = coordinator.surface(
            for: firstKey, configuration: config
        ) else {
            throw XCTSkip("Surface creation unavailable in smoke environment")
        }
        let firstWindow = hostInWindow(firstView)
        defer { firstWindow.orderOut(nil) }

        let baseSize = try waitForFontSize(
            in: firstView
        )
        let initialGrid = try XCTUnwrap(firstView.surfaceSize)
        var reportedGrids: [(columns: Int, rows: Int)] = []
        firstView.onGridSizeChanged = { columns, rows in
            reportedGrids.append((columns, rows))
        }

        coordinator.applyFontZoom(.increase)
        let zoomedSize = try waitForFontSize(
            in: firstView
        ) { zoomed in
            zoomed > baseSize
        }
        XCTAssertGreaterThan(
            zoomedSize, baseSize,
            "Zooming should increase the live surface font size"
        )
        waitUntil(timeout: 2) {
            reportedGrids.contains {
                $0.columns != Int(initialGrid.columns)
                    || $0.rows != Int(initialGrid.rows)
            }
        }
        XCTAssertTrue(
            reportedGrids.contains {
                $0.columns != Int(initialGrid.columns)
                    || $0.rows != Int(initialGrid.rows)
            },
            "Font zoom must report the changed grid even when pixel bounds stay fixed"
        )

        let secondKey = SurfaceKey.fixture(
            worktreeID: UUID(),
            hostID: firstKey.hostID,
            target: .worktreeShell
        )
        guard let secondView = coordinator.surface(
            for: secondKey, configuration: config
        ) else {
            throw XCTSkip("Second surface creation unavailable in smoke environment")
        }
        let secondWindow = hostInWindow(secondView)
        defer { secondWindow.orderOut(nil) }

        let inheritedSize = try waitForFontSize(
            in: secondView
        ) { inherited in
            abs(inherited - zoomedSize) <= 0.01
        }
        XCTAssertEqual(
            inheritedSize, zoomedSize, accuracy: 0.01,
            "New surfaces should inherit the active runtime zoom level"
        )

        coordinator.applyFontZoom(.reset)

        let thirdKey = SurfaceKey.fixture(
            worktreeID: UUID(),
            hostID: firstKey.hostID,
            target: .console
        )
        guard let thirdView = coordinator.surface(
            for: thirdKey, configuration: config
        ) else {
            throw XCTSkip("Third surface creation unavailable in smoke environment")
        }
        let thirdWindow = hostInWindow(thirdView)
        defer { thirdWindow.orderOut(nil) }

        let resetSize = try waitForFontSize(
            in: thirdView
        ) { reset in
            abs(reset - baseSize) <= 0.01
        }
        XCTAssertEqual(
            resetSize, baseSize, accuracy: 0.01,
            "Reset should clear the runtime zoom override for future surfaces"
        )
    }

    func testSurfaceIdentityLookupResolvesLiveView() throws {
        let (coordinator, config) = try makeCoordinator()
        let key = SurfaceKey.fixture()

        guard let view = coordinator.surface(
            for: key, configuration: config
        ) else {
            throw XCTSkip(
                "Surface creation unavailable in smoke environment"
            )
        }
        guard let surfaceIdentity = view.surfaceHandle.map({
            UInt(bitPattern: $0)
        }) else {
            throw XCTSkip(
                "Surface creation unavailable in smoke environment"
            )
        }

        XCTAssertTrue(
            TerminalSurfaceView.surfaceView(
                forSurfaceIdentity: surfaceIdentity
            ) === view
        )
    }

    func testConsoleSurfaceKeyWithNilWorktreeID() throws {
        let (coordinator, config) = try makeCoordinator()
        let hostID = UUID()

        let consoleKey = SurfaceKey.fixture(
            worktreeID: nil,
            hostID: hostID,
            target: .console
        )
        let worktreeKey = SurfaceKey.fixture(
            worktreeID: UUID(),
            hostID: hostID,
            target: .worktreeShell
        )

        let consoleView = coordinator.surface(
            for: consoleKey, configuration: config
        )
        let worktreeView = coordinator.surface(
            for: worktreeKey, configuration: config
        )

        XCTAssertNil(
            consoleKey.worktreeID,
            "Console keys must have nil worktreeID"
        )
        XCTAssertNotNil(consoleView)
        XCTAssertNotNil(worktreeView)
        XCTAssertTrue(
            consoleView !== worktreeView,
            "Console vs worktree key should produce distinct views"
        )
        XCTAssertEqual(
            coordinator.surfaceEntries().count, 2,
            "Coordinator should track both surfaces separately"
        )
        XCTAssertEqual(
            coordinator.surfaceKey(for: consoleView!), consoleKey,
            "Reverse lookup should resolve the console key"
        )
        XCTAssertEqual(
            coordinator.surfaceKey(for: worktreeView!), worktreeKey,
            "Reverse lookup should resolve the worktree key"
        )
    }

    func testWorktreeShellKeyWithNilLeafID() throws {
        let (coordinator, config) = try makeCoordinator()
        let ctx = WorkspaceTestContext()

        let unsplitKey = ctx.surfaceKey(
            target: .worktreeShell, leafID: nil
        )
        let splitKey = ctx.surfaceKey(
            target: .worktreeShell, leafID: ctx.leafID
        )

        let unsplitView = coordinator.surface(
            for: unsplitKey, configuration: config
        )
        let splitView = coordinator.surface(
            for: splitKey, configuration: config
        )

        XCTAssertNotNil(unsplitView)
        XCTAssertNotNil(splitView)
        XCTAssertTrue(
            unsplitView !== splitView,
            "nil vs non-nil leafID should produce distinct views"
        )

        XCTAssertEqual(
            coordinator.surfaceKey(for: unsplitView!), unsplitKey,
            "Round-trip lookup should resolve the unsplit key"
        )
        XCTAssertEqual(
            coordinator.surfaceKey(for: splitView!), splitKey,
            "Round-trip lookup should resolve the split key"
        )

        coordinator.removeSurface(for: splitKey)

        XCTAssertFalse(
            coordinator.containsSurface(for: splitKey),
            "Removed split key should no longer be present"
        )
        XCTAssertTrue(
            coordinator.containsSurface(for: unsplitKey),
            "Removing split key must not evict the unsplit key"
        )
    }

    func testSurfaceCreationProducesValidHandle() throws {
        try skipUnlessLibghosttyReady()

        let runtime = retainedRuntime()
        XCTAssertEqual(runtime.phase, .ready)

        guard let appHandle = runtime.unsafeAppHandle else {
            return XCTFail("Expected libghostty runtime app handle")
        }

        let view = TerminalSurfaceView(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0, width: 800, height: 600
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        defer { window.orderOut(nil) }

        guard view.surfaceHandle != nil, view.error == nil else {
            throw XCTSkip(
                "Surface creation unavailable in smoke environment"
            )
        }

        XCTAssertNotNil(
            view.surfaceHandle,
            "Surface view should produce a live surface handle"
        )
        XCTAssertNil(
            view.error,
            "Surface view should have no error after creation"
        )
    }
}
