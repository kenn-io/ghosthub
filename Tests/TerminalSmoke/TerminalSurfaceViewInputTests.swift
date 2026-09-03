import AppKit
import Combine
import Foundation
import GhosttyKit
@testable import GhosthubApp
import GhosthubTestSupport
import GhosthubUI
import GhosthubWorkspace
import SwiftUI
import XCTest
@testable import GhosthubTerminal
@testable import GhosthubTerminalSupport

@MainActor
final class TerminalSurfaceViewInputTests: XCTestCase {
    // Retained across the entire test suite so ghostty_app_free is
    // never called while deferred ghostty_surface_free tasks are
    // still pending.
    private static var retainedRuntime: LibghosttyRuntime?
    private static var transientRuntimes: [LibghosttyRuntime] = []
    private var pasteboard: InMemoryTerminalPasteboard!
    private var surfaces: [TerminalSurfaceView] = []

    override func setUp() async throws {
        try await super.setUp()
        try skipUnlessLibghosttyReady()
        pasteboard = InMemoryTerminalPasteboard()
        TerminalPasteboardAccess.current = pasteboard
        LibghosttyRuntime.osc52ClipboardWriteDiagnosticObserver = nil
    }

    override func tearDown() async throws {
        for surface in surfaces {
            await surface.shutdown()
        }
        surfaces.removeAll()
        LibghosttyRuntime.osc52ClipboardWriteDiagnosticObserver = nil
        TerminalPasteboardAccess.reset()
        pasteboard = nil
        try await super.tearDown()
    }

    private func makeSurface(
        app: ghostty_app_t,
        configuration: TerminalSurfaceConfiguration,
        keyEventInterpreter: (([NSEvent]) -> Void)? = nil,
        textInputObserver: ((String) -> Void)? = nil,
        commandObserver: ((Selector) -> Void)? = nil
    ) -> TerminalSurfaceView {
        let surface = TerminalSurfaceView(
            app: app,
            configuration: configuration,
            keyEventInterpreter: keyEventInterpreter,
            textInputObserver: textInputObserver,
            commandObserver: commandObserver
        )
        surfaces.append(surface)
        return surface
    }

    private func requireAppHandle(
        from runtime: LibghosttyRuntime? = nil
    ) throws -> ghostty_app_t {
        let r = runtime ?? retainedRuntime()
        return try XCTUnwrap(
            r.unsafeAppHandle,
            "libghostty runtime app handle unavailable"
        )
    }

    private func makeExecutableScript(_ contents: String) -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try! contents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func makeRawInputProbeScript(readBytes: Int) -> URL {
        makeExecutableScript(
            """
            #!/usr/bin/env python3
            import os
            import termios
            import tty
            import sys

            fd = sys.stdin.fileno()
            old = termios.tcgetattr(fd)
            print("<READY>", flush=True)
            try:
                tty.setraw(fd)
                data = os.read(fd, \(readBytes))
                print(f"<RAW:{data.hex()}>", flush=True)
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
            """
        )
    }

    private func makeBracketedPasteProbeScript(
        readBytes: Int
    ) -> URL {
        makeExecutableScript(
            """
            #!/usr/bin/env python3
            import os
            import sys
            import termios
            import tty

            fd = sys.stdin.fileno()
            old = termios.tcgetattr(fd)
            os.write(sys.stdout.fileno(), b"\\x1b[?2004h")
            print("<READY>", flush=True)
            try:
                tty.setraw(fd)
                data = bytearray()
                while len(data) < \(readBytes):
                    chunk = os.read(fd, \(readBytes) - len(data))
                    if not chunk:
                        break
                    data.extend(chunk)
                print(f"<RAW:{data.hex()}>", flush=True)
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
                os.write(sys.stdout.fileno(), b"\\x1b[?2004l")
            """
        )
    }

    private func makeOSC52ReadProbeScript() -> URL {
        makeExecutableScript(
            """
            #!/usr/bin/env python3
            import os
            import select
            import sys
            import termios
            import tty

            fd = sys.stdin.fileno()
            old = termios.tcgetattr(fd)
            print("<READY>", flush=True)
            try:
                tty.setraw(fd)
                os.write(sys.stdout.fileno(), b"\\x1b]52;c;?\\x07")
                readable, _, _ = select.select([fd], [], [], 3)
                data = os.read(fd, 256) if readable else b""
            finally:
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
            print(f"<OSC52:{data.hex()}>", flush=True)
            """
        )
    }

    private func makeEnvironmentProbeScript(_ names: [String]) -> URL {
        let body = names.map { name in
            "print(\(name.debugDescription) + '=' + os.environ.get(\(name.debugDescription), ''))"
        }.joined(separator: "\n")

        return makeExecutableScript(
            """
            #!/usr/bin/env python3
            import os
            \(body)
            """
        )
    }

    private func retainedRuntime() -> LibghosttyRuntime {
        if Self.retainedRuntime == nil {
            let (pipeline, _) = makeIsolatedSurfacePipeline()
            try! FileManager.default.createDirectory(
                at: pipeline.paths.configDirectory,
                withIntermediateDirectories: true
            )
            try! "shell = /bin/zsh\n".write(
                to: pipeline.paths.globalConfigFile,
                atomically: true,
                encoding: .utf8
            )
            Self.retainedRuntime = LibghosttyRuntime(pipeline: pipeline)
        }
        return Self.retainedRuntime!
    }

    private func runtimeWithTerminalConfig(
        _ contents: String
    ) throws -> LibghosttyRuntime {
        let (pipeline, _) = makeIsolatedSurfacePipeline()
        try FileManager.default.createDirectory(
            at: pipeline.paths.configDirectory,
            withIntermediateDirectories: true
        )
        try ("shell = /bin/zsh\n" + contents).write(
            to: pipeline.paths.globalConfigFile,
            atomically: true,
            encoding: .utf8
        )

        let runtime = LibghosttyRuntime(pipeline: pipeline)
        XCTAssertEqual(runtime.phase, .ready)
        Self.transientRuntimes.append(runtime)
        return runtime
    }

    private func runtimeWithClipboardReadsAllowed() throws -> LibghosttyRuntime {
        try runtimeWithTerminalConfig("clipboard-read = allow\n")
    }

    private func makeShellHome(
        rcFileName: String? = nil,
        rcContents: String? = nil
    ) -> URL {
        let homeDirectory = makeTemporaryDirectory()
        if let rcFileName, let rcContents {
            let rcFile = homeDirectory.appendingPathComponent(
                rcFileName, isDirectory: false
            )
            try! rcContents.write(
                to: rcFile, atomically: true, encoding: .utf8
            )
        }
        return homeDirectory
    }

    private func makeZshConfiguration(
        rcContents: String
    ) -> TerminalSurfaceConfiguration {
        let home = makeShellHome(
            rcFileName: ".zshrc", rcContents: rcContents
        )
        return TerminalSurfaceConfiguration(
            command: "/bin/zsh",
            environmentVariables: [
                "HOME": home.path,
                "ZDOTDIR": home.path,
            ]
        )
    }

    private func makeInteractiveBashConfiguration() -> TerminalSurfaceConfiguration {
        let home = makeShellHome()
        return TerminalSurfaceConfiguration(
            environmentVariables: [
                "HOME": home.path,
                "ZDOTDIR": home.path,
            ],
            initialInput:
            "exec env HOME='\(home.path)' "
                + "PS1='PROMPT> ' "
                + "BASH_SILENCE_DEPRECATION_WARNING=1 "
                + "/bin/bash --noprofile --norc -i\n"
        )
    }

    private func makeInteractiveEmacsZshConfiguration() -> TerminalSurfaceConfiguration {
        makeZshConfiguration(rcContents: """
        bindkey -e
        PROMPT='PROMPT> '
        RPROMPT=''
        """)
    }

    private func makeDefaultLocalZshConfiguration() -> TerminalSurfaceConfiguration {
        makeZshConfiguration(rcContents: """
        print -r -- "<ZSHRC_LOADED>"
        PROMPT='PROMPT> '
        RPROMPT=''
        """)
    }

    private func makeKeyEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int = 0,
        isARepeat: Bool = false
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: isARepeat,
            keyCode: keyCode
        )!
    }

    private func makeKeyUpEvent(
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int = 0
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyUp,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 1,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private func makeLeftMouseDownEvent(
        windowNumber: Int,
        location: NSPoint = NSPoint(x: 40, y: 40)
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func makeTestWindow(
        contentView: NSView,
        size: CGSize = CGSize(width: 960, height: 640),
        settleDelay: TimeInterval = 0.25,
        requiresActiveApplication: Bool = false
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        if requiresActiveApplication {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.unhide(nil)
            window.orderFrontRegardless()
        }
        window.makeKeyAndOrderFront(nil)
        if requiresActiveApplication {
            NSRunningApplication.current.activate(
                options: [.activateAllWindows]
            )
        }
        window.displayIfNeeded()
        waitUntil(timeout: 1.0) { window.isKeyWindow }
        RunLoop.main.run(
            until: Date().addingTimeInterval(settleDelay)
        )
        return window
    }

    private func hostInWindow(
        _ view: TerminalSurfaceView,
        size: CGSize = CGSize(width: 960, height: 640),
        requiresActiveApplication: Bool = false
    ) -> NSWindow {
        let window = makeTestWindow(
            contentView: view,
            size: size,
            settleDelay: 0.1,
            requiresActiveApplication: requiresActiveApplication
        )
        window.makeFirstResponder(view)
        view.focusDidChange(true)
        view.sizeDidChange(size)
        return window
    }

    private func hostSwiftUIWindow<Content: View>(
        rootView: Content,
        size: CGSize = CGSize(width: 960, height: 640)
    ) -> NSWindow {
        makeTestWindow(
            contentView: NSHostingView(rootView: rootView),
            size: size
        )
    }

    private func hostInSwiftUIWindow(
        _ view: TerminalSurfaceView,
        size: CGSize = CGSize(width: 960, height: 640)
    ) -> NSWindow {
        let window = hostSwiftUIWindow(
            rootView: TerminalSurfaceSwiftUIView(surfaceView: view),
            size: size
        )
        window.makeFirstResponder(view)
        view.focusDidChange(true)
        return window
    }

    private func hostInWorkspaceWindow(
        size: CGSize = CGSize(width: 960, height: 640),
        tmuxContentBuilder: @escaping () -> AnyView?
    ) -> NSWindow {
        let bootstrap = WorkspaceBootstrap.preview()
        var snapshot = bootstrap.snapshot
        let selectedWorktreeID = bootstrap.selection.selectedWorktreeID
        if let selectedWorktreeID,
           let index = snapshot.worktrees.firstIndex(
               where: { $0.id == selectedWorktreeID }
           ) {
            snapshot.worktrees[index].tmuxSessionName = "test-session"
        }
        var selection = bootstrap.selection
        var columnVisibility = NavigationSplitViewVisibility.all
        var isCommandPalettePresented = false
        let activeTmuxSession = WorkspaceSidebarModel
            .tmuxSessionSelection(
                for: selection,
                in: snapshot
            )

        let rootView = RootView(
            display: WorkspaceDisplayState(
                snapshot: snapshot,
                activeTmuxSession: activeTmuxSession
            ),
            content: ContentBuilders(
                tmuxSessionContentBuilder: { _, _, _, _ in
                    tmuxContentBuilder()
                }
            ),
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            columnVisibility: Binding(
                get: { columnVisibility },
                set: { columnVisibility = $0 }
            ),
            isCommandPalettePresented: Binding(
                get: { isCommandPalettePresented },
                set: { isCommandPalettePresented = $0 }
            )
        )

        return makeTestWindow(
            contentView: NSHostingView(rootView: rootView),
            size: size,
            settleDelay: 0.5
        )
    }

    private func hostInGhosthubWorkspaceWindow(
        _ view: TerminalSurfaceView,
        size: CGSize = CGSize(width: 960, height: 640)
    ) -> NSWindow {
        let window = hostInWorkspaceWindow(
            size: size,
            tmuxContentBuilder: {
                return AnyView(TerminalSurfaceSwiftUIView(surfaceView: view))
            }
        )
        window.makeFirstResponder(view)
        view.focusDidChange(true)
        return window
    }

    private func descendantViews(
        in rootView: NSView?
    ) -> [NSView] {
        guard let rootView else { return [] }

        var result: [NSView] = [rootView]
        for subview in rootView.subviews {
            result.append(contentsOf: descendantViews(in: subview))
        }
        return result
    }

    private func sendText(
        _ text: String,
        to view: TerminalSurfaceView
    ) {
        guard let surface = view.surfaceHandle else {
            XCTFail("Expected surface handle")
            return
        }

        let length = text.utf8CString.count - 1
        text.withCString { pointer in
            ghostty_surface_text(surface, pointer, UInt(length))
        }
    }

    private func typeText(
        _ text: String,
        into view: TerminalSurfaceView,
        window: NSWindow? = nil
    ) {
        for scalar in text.unicodeScalars {
            let value = String(scalar)
            let keyCode: UInt16
            switch value {
            case "a": keyCode = 0
            case "b": keyCode = 11
            case "c": keyCode = 8
            case "d": keyCode = 2
            case "e": keyCode = 14
            case "h": keyCode = 4
            case "o": keyCode = 31
            case "x": keyCode = 7
            case "X": keyCode = 7
            case " ": keyCode = 49
            case "\r": keyCode = 36
            default:
                sendText(value, to: view)
                continue
            }

            let event = makeKeyEvent(
                characters: value,
                charactersIgnoringModifiers: value.lowercased(),
                modifiers: value == "X" ? [.shift] : [],
                keyCode: keyCode,
                windowNumber: window?.windowNumber ?? 0
            )
            if let window {
                window.sendEvent(event)
            } else {
                view.keyDown(with: event)
            }
        }
    }

    private func readViewportText(
        from view: TerminalSurfaceView
    ) -> String {
        guard let surface = view.surfaceHandle else {
            return ""
        }

        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return ""
        }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if condition() {
                return
            }
        }
    }

    private func waitForViewportText(
        _ expected: String,
        in view: TerminalSurfaceView,
        timeout: TimeInterval = 5.0
    ) {
        waitUntil(timeout: timeout) {
            self.readViewportText(from: view).contains(expected)
        }
    }

    private enum HostMode {
        case appKit
        case swiftUI
    }

    private enum EventRoute {
        case window
        case application
    }

    private func hostWindow(
        for view: TerminalSurfaceView,
        mode: HostMode,
        size: CGSize = CGSize(width: 960, height: 640)
    ) -> NSWindow {
        switch mode {
        case .appKit:
            return hostInWindow(view, size: size)
        case .swiftUI:
            return hostInSwiftUIWindow(view, size: size)
        }
    }

    private func interactiveChordTextMatches(
        in view: TerminalSurfaceView,
        successText: String,
        commandNotFoundText: String
    ) -> Bool {
        let contents = readViewportText(from: view)
        return contents.contains(successText)
            || contents.contains(commandNotFoundText)
    }

    private func dispatch(
        _ event: NSEvent,
        to window: NSWindow,
        route: EventRoute
    ) {
        switch route {
        case .window:
            window.sendEvent(event)
        case .application:
            NSApplication.shared.sendEvent(event)
        }
    }

    private func settleInputPipeline() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func waitForProbeReady(in view: TerminalSurfaceView) {
        waitForViewportText("<READY>", in: view, timeout: 5.0)
    }

    @MainActor
    private final class ObserverHarness {
        private let storage = Storage()
        let view: TerminalSurfaceView

        var inserted: [String] { storage.inserted }
        var commands: [String] { storage.commands }

        init(
            appHandle: ghostty_app_t,
            owner: TerminalSurfaceViewInputTests
        ) {
            let s = storage
            view = owner.makeSurface(
                app: appHandle,
                configuration: TerminalSurfaceConfiguration(),
                textInputObserver: { s.inserted.append($0) },
                commandObserver: {
                    s.commands.append(NSStringFromSelector($0))
                }
            )
        }

        private final class Storage {
            var inserted: [String] = []
            var commands: [String] = []
        }
    }

    private func assertPTYReceives(
        readBytes: Int,
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        route: EventRoute = .window,
        expectedRaw: String,
        message: String,
        hostBuilder: (TerminalSurfaceView, CGSize) -> NSWindow
    ) throws {
        let appHandle = try requireAppHandle()
        let scriptURL = makeRawInputProbeScript(readBytes: readBytes)
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        let window = hostBuilder(view, CGSize(width: 800, height: 600))
        waitUntil(timeout: 5.0) { view.error == nil }
        if view.window !== window {
            waitUntil(timeout: 2.0) { view.window === window }
        }
        waitForProbeReady(in: view)

        dispatch(
            makeKeyEvent(
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifiers: modifiers,
                keyCode: keyCode,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: route
        )
        waitForViewportText("<RAW:\(expectedRaw)>", in: view)

        let contents = readViewportText(from: view)
        XCTAssertTrue(
            contents.contains("<RAW:\(expectedRaw)>"),
            "\(message). Contents: \(contents)"
        )
    }

    private func withTemporaryEnvironment<T>(
        _ overrides: [String: String?],
        body: () throws -> T
    ) rethrows -> T {
        var originalValues: [String: String?] = [:]
        for key in overrides.keys {
            if let value = getenv(key) {
                originalValues[key] = String(cString: value)
            } else {
                originalValues[key] = nil
            }
        }

        for (key, value) in overrides {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }

        defer {
            for (key, value) in originalValues {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        return try body()
    }

    func testControlChordUsesInterpretKeyEventsOnSurfaceView() throws {
        let appHandle = try requireAppHandle()

        var interpretedEvents = 0
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(),
            keyEventInterpreter: { _ in interpretedEvents += 1 }
        )
        let window = hostInWindow(view)

        let event = makeKeyEvent(
            characters: "\u{1}",
            charactersIgnoringModifiers: "a",
            modifiers: [.control],
            keyCode: 0,
            windowNumber: window.windowNumber
        )

        window.sendEvent(event)

        XCTAssertEqual(
            interpretedEvents,
            1,
            "libghostty should use the standard AppKit translation path for control chords"
        )
    }

    func testPlainCharacterStillUsesInterpretKeyEventsOnSurfaceView() throws {
        let appHandle = try requireAppHandle()

        var interpretedEvents = 0
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(),
            keyEventInterpreter: { _ in interpretedEvents += 1 }
        )
        _ = hostInWindow(view)

        let event = makeKeyEvent(
            characters: "a",
            charactersIgnoringModifiers: "a",
            modifiers: [],
            keyCode: 0
        )

        view.keyDown(with: event)

        XCTAssertEqual(
            interpretedEvents,
            1,
            "Plain text input should continue to use AppKit text interpretation"
        )
    }

    func testControlChordsMapToAppKitCommandSelectors() throws {
        let appHandle = try requireAppHandle()
        let harness = ObserverHarness(appHandle: appHandle, owner: self)
        let window = hostInWindow(harness.view)

        for event in [
            makeKeyEvent(
                characters: "\u{1}",
                charactersIgnoringModifiers: "a",
                modifiers: [.control],
                keyCode: 0,
                windowNumber: window.windowNumber
            ),
            makeKeyEvent(
                characters: "\u{5}",
                charactersIgnoringModifiers: "e",
                modifiers: [.control],
                keyCode: 14,
                windowNumber: window.windowNumber
            ),
        ] {
            window.sendEvent(event)
        }

        XCTAssertEqual(harness.inserted, [])
        XCTAssertEqual(
            harness.commands,
            ["moveToBeginningOfParagraph:", "moveToEndOfParagraph:"],
            "Control chords should still map through AppKit's text interpretation selectors."
        )
    }

    func testReservedAppShortcutBypassesTerminalDispatchState() throws {
        let appHandle = try requireAppHandle()
        let harness = ObserverHarness(appHandle: appHandle, owner: self)
        let window = hostInWindow(harness.view)

        let event = makeKeyEvent(
            characters: "q",
            charactersIgnoringModifiers: "q",
            modifiers: [.command],
            keyCode: 12,
            windowNumber: window.windowNumber
        )

        XCTAssertFalse(
            harness.view.performKeyEquivalent(with: event),
            "Reserved app shortcuts must bypass terminal redispatch so the app menu can handle them."
        )
        XCTAssertEqual(harness.inserted, [])
        XCTAssertEqual(harness.commands, [])
    }

    func testMenuOwnedSidebarReleaseStopsBeforeTerminalDispatch() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let shortcuts = try ApplicationShortcutCatalog.resolve(overrides: [
            .toggleSidebar: .binding(
                try ApplicationKeyBinding(parsing: "ctrl+b")
            ),
        ])
        view.applicationShortcutsProvider = { shortcuts }
        let first = ShortcutMonitor(
            shortcuts: { shortcuts },
            perform: { _ in true }
        )
        let second = ShortcutMonitor(
            shortcuts: { shortcuts },
            perform: { _ in true }
        )
        let keyDown = makeKeyEvent(
            characters: "\u{2}",
            charactersIgnoringModifiers: "b",
            modifiers: [.control],
            keyCode: 11
        )
        let keyUp = makeKeyUpEvent(
            characters: "b",
            charactersIgnoringModifiers: "b",
            modifiers: [.control],
            keyCode: 11
        )

        let menuEvent = first.processForTesting(keyDown)
            .flatMap { second.processForTesting($0) }
        XCTAssertNotNil(menuEvent)

        let terminalEvent = first.processForTesting(keyUp)
            .flatMap { second.processForTesting($0) }
        XCTAssertNil(
            terminalEvent,
            "The menu-owned release must stop before the terminal or libghostty can observe it."
        )
    }

    func testTmuxSplitShortcutsReachAttachedClientHandler() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        var shortcuts: [TerminalPaneSplitShortcut] = []
        view.paneSplitShortcutHandler = { shortcuts.append($0) }

        for event in [
            makeKeyEvent(
                characters: "d",
                charactersIgnoringModifiers: "d",
                modifiers: .command,
                keyCode: 2,
                windowNumber: 0
            ),
            makeKeyEvent(
                characters: "D",
                charactersIgnoringModifiers: "d",
                modifiers: [.command, .shift],
                keyCode: 2,
                windowNumber: 0
            ),
        ] {
            XCTAssertTrue(view.handlePaneSplitShortcutForTesting(event))
        }

        XCTAssertEqual(shortcuts, [.right, .down])
    }

    func testTmuxSplitShortcutRepeatIsConsumedWithoutSplitting() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        var shortcuts: [TerminalPaneSplitShortcut] = []
        view.paneSplitShortcutHandler = { shortcuts.append($0) }
        let event = makeKeyEvent(
            characters: "d",
            charactersIgnoringModifiers: "d",
            modifiers: .command,
            keyCode: 2,
            isARepeat: true
        )

        XCTAssertTrue(view.handlePaneSplitShortcutForTesting(event))
        XCTAssertEqual(shortcuts, [])
    }

    func testTmuxSplitShortcutConsumesKeyUpAfterCommandRelease() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        view.paneSplitShortcutHandler = { _ in }
        let keyDown = makeKeyEvent(
            characters: "d",
            charactersIgnoringModifiers: "d",
            modifiers: .command,
            keyCode: 2
        )
        let keyUp = makeKeyUpEvent(
            characters: "d",
            charactersIgnoringModifiers: "d",
            modifiers: [],
            keyCode: 2
        )

        XCTAssertTrue(view.handlePaneSplitShortcutForTesting(keyDown))
        XCTAssertNil(view.processLocalEventForTesting(keyUp))
    }

    func testCommandShiftBracketsAreReservedForTabNavigation() throws {
        let appHandle = try requireAppHandle()
        let harness = ObserverHarness(appHandle: appHandle, owner: self)
        let window = hostInWindow(harness.view)

        // Cmd-Shift-] (keyCode 30)
        let nextTabEvent = makeKeyEvent(
            characters: "}",
            charactersIgnoringModifiers: "]",
            modifiers: [.command, .shift],
            keyCode: 30,
            windowNumber: window.windowNumber
        )
        XCTAssertFalse(
            harness.view.performKeyEquivalent(with: nextTabEvent),
            "Cmd-Shift-] should be reserved for app tab navigation."
        )
        // Also verify the local event monitor passes it through
        let localResult = harness.view.processLocalEventForTesting(
            nextTabEvent
        )
        XCTAssertNotNil(
            localResult,
            "Cmd-Shift-] must not be consumed by localEventKeyDown."
        )

        // Cmd-Shift-[ (keyCode 33)
        let prevTabEvent = makeKeyEvent(
            characters: "{",
            charactersIgnoringModifiers: "[",
            modifiers: [.command, .shift],
            keyCode: 33,
            windowNumber: window.windowNumber
        )
        XCTAssertFalse(
            harness.view.performKeyEquivalent(with: prevTabEvent),
            "Cmd-Shift-[ should be reserved for app tab navigation."
        )
        let localResult2 = harness.view.processLocalEventForTesting(
            prevTabEvent
        )
        XCTAssertNotNil(
            localResult2,
            "Cmd-Shift-[ must not be consumed by localEventKeyDown."
        )
    }

    func testTerminalYieldsKeyboardFocusWhenSheetIsAttached() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view, requiresActiveApplication: true)
        waitUntil(timeout: 2.0) {
            view.window === window
                && view.focused
                && window.isKeyWindow
        }
        guard window.isKeyWindow else {
            throw XCTSkip(
                "Test requires window server"
                    + " - skipping in headless environment"
            )
        }

        let event = makeKeyEvent(
            characters: "c",
            charactersIgnoringModifiers: "c",
            modifiers: [.command],
            keyCode: 8,
            windowNumber: window.windowNumber
        )

        // With no sheet, the event should be consumed by the terminal
        let resultWithoutSheet = view.processLocalEventForTesting(event)
        XCTAssertNil(
            resultWithoutSheet,
            "Cmd-C should be consumed when no sheet is present."
        )

        // Attach a sheet with a text field as first responder
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textField = NSTextField(
            frame: NSRect(x: 10, y: 10, width: 280, height: 24)
        )
        sheet.contentView?.addSubview(textField)
        window.beginSheet(sheet)

        // Wait for the sheet to fully attach before checking focus
        waitUntil(timeout: 2.0) {
            window.attachedSheet === sheet
        }
        XCTAssertTrue(
            sheet.makeFirstResponder(textField),
            "Text field should accept first responder in the sheet."
        )

        let resultWithSheet = view.processLocalEventForTesting(event)
        XCTAssertNotNil(
            resultWithSheet,
            "Cmd-C should pass through when a sheet is attached."
        )

        // After dismissing the sheet, terminal should reclaim focus
        window.endSheet(sheet)
        window.makeKeyAndOrderFront(nil)
        waitUntil(timeout: 2.0) {
            window.isKeyWindow && window.attachedSheet == nil
        }

        let resultAfterDismiss = view.processLocalEventForTesting(event)
        XCTAssertNil(
            resultAfterDismiss,
            "Cmd-C should be consumed again after sheet is dismissed."
        )
    }

    func testCommandPlusUsesSessionFontZoomHandler() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)
        waitUntil(timeout: 2.0) {
            view.window === window && view.focused
        }
        var handledCommands: [TerminalFontZoomCommand] = []
        view.fontZoomShortcutHandler = { command in
            handledCommands.append(command)
            return true
        }

        let event = makeKeyEvent(
            characters: "+",
            charactersIgnoringModifiers: "=",
            modifiers: [.command, .shift],
            keyCode: 24,
            windowNumber: window.windowNumber
        )

        XCTAssertTrue(
            view.handleFontZoomShortcutForTesting(event),
            "Cmd-+ should map to Ghosthub's runtime zoom command."
        )
        XCTAssertEqual(handledCommands, [.increase])
    }

    func testOptionDObservedAppKitCallbacksDoNotInvokeCommands() throws {
        let appHandle = try requireAppHandle()
        let harness = ObserverHarness(appHandle: appHandle, owner: self)
        let window = hostInWindow(harness.view)

        let event = makeKeyEvent(
            characters: "d",
            charactersIgnoringModifiers: "d",
            modifiers: [.option],
            keyCode: 2,
            windowNumber: window.windowNumber
        )

        window.sendEvent(event)

        XCTAssertLessThanOrEqual(harness.inserted.count, 1)
        XCTAssertTrue(
            harness.inserted.allSatisfy { $0 == "d" },
            "Option-modified printable keys should not surface unexpected AppKit text when the PTY path is handling Meta-D."
        )
        XCTAssertEqual(harness.commands, [])
    }

    func testSwiftUIWrapperKeepsTerminalFocusedForControlChords() throws {
        let appHandle = try requireAppHandle()

        var interpretedEvents = 0
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(),
            keyEventInterpreter: { _ in interpretedEvents += 1 }
        )
        let window = hostInSwiftUIWindow(view)

        waitUntil(timeout: 2.0) {
            view.window === window && view.focused
        }
        XCTAssertTrue(
            view.focused,
            "SwiftUI hosting should preserve the terminal's AppKit focus state"
        )

        let event = makeKeyEvent(
            characters: "\u{1}",
            charactersIgnoringModifiers: "a",
            modifiers: [.control],
            keyCode: 0,
            windowNumber: window.windowNumber
        )

        window.sendEvent(event)

        XCTAssertEqual(
            interpretedEvents,
            1,
            "Control chords should still use AppKit translation when the terminal is hosted in SwiftUI"
        )
    }

    func testApplicationDispatchedMouseDownNotifiesPrimaryInteractionExactlyOnce() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view, requiresActiveApplication: true)
        guard window.isKeyWindow else {
            throw XCTSkip(
                "Test requires window server - skipping in headless environment"
            )
        }

        var interactions = 0
        var focusedTransitions = 0
        view.onPrimaryInteraction = { interactions += 1 }
        view.onFocusChange = { focused in
            if focused {
                focusedTransitions += 1
            }
        }

        window.makeFirstResponder(nil)
        view.focusDidChange(false)
        settleInputPipeline()

        dispatch(
            makeLeftMouseDownEvent(windowNumber: window.windowNumber),
            to: window,
            route: .application
        )

        XCTAssertEqual(
            interactions,
            1,
            "A real application-dispatched click should notify pane activation exactly once."
        )
        XCTAssertEqual(
            focusedTransitions,
            1,
            "An unfocused pane click should repair focus state exactly once."
        )
    }

    func testRemovingOlderPaneObserverDoesNotClearNewerPaneObserver() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)

        let oldID = UUID()
        let newID = UUID()
        var oldInteractions = 0
        var newInteractions = 0

        view.registerPaneFocusObserver(
            id: oldID,
            onFocusChange: { _ in },
            onPrimaryInteraction: { oldInteractions += 1 }
        )
        view.registerPaneFocusObserver(
            id: newID,
            onFocusChange: { _ in },
            onPrimaryInteraction: { newInteractions += 1 }
        )

        view.unregisterPaneFocusObserver(id: oldID)
        dispatch(
            makeLeftMouseDownEvent(windowNumber: window.windowNumber),
            to: window,
            route: .application
        )

        XCTAssertEqual(oldInteractions, 0)
        XCTAssertEqual(
            newInteractions,
            1,
            "Removing an older pane observer must not clear a newer binding for the same surface."
        )
    }

    func testPaneCloseObserversReceiveCloseRequests() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        _ = hostInWindow(view)
        let observerID = UUID()
        var closeRequests = 0

        view.registerPaneCloseRequestObserver(
            id: observerID,
            onCloseRequest: { closeRequests += 1 }
        )

        view.notifyCloseRequestForTesting()

        XCTAssertEqual(
            closeRequests,
            1,
            "Pane close observers should be notified when the terminal requests a pane close."
        )
    }

    func testSurfaceClosedErrorNotifiesSurfaceCloseObserver() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let observerID = UUID()
        var reportedProcessAlive: Bool?

        view.registerSurfaceCloseObserver(
            id: observerID,
            onSurfaceClosed: { reportedProcessAlive = $0 }
        )
        view.error = TerminalSurfaceError.surfaceClosed(processAlive: false)

        XCTAssertEqual(
            reportedProcessAlive,
            false,
            "Surface close observers should be notified when libghostty closes a shell surface."
        )
    }

    func testClosingSurfaceCapturesSuccessfulChildExitCode() throws {
        let runtime = try runtimeWithTerminalConfig(
            "abnormal-command-exit-runtime = 0\n"
        )
        let appHandle = try requireAppHandle(from: runtime)
        let home = makeShellHome()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                environmentVariables: [
                    "HOME": home.path,
                    "SHELL": "/bin/zsh",
                    "ZDOTDIR": home.path,
                ],
                initialInput: "exec /bin/sh -c 'sleep 1; exit 0'\n"
            )
        )
        let window = hostInWindow(view)
        var reportedProcessAlive: Bool?
        view.registerSurfaceCloseObserver(id: UUID()) {
            reportedProcessAlive = $0
        }

        waitUntil(timeout: 10.0) {
            view.surfaceHandle.map(ghostty_surface_process_exited) == true
        }
        let surface = try XCTUnwrap(view.surfaceHandle)
        XCTAssertTrue(ghostty_surface_process_exited(surface))

        // The action callback also reports this status. Clear it so the
        // assertion below proves the close callback obtains the code from
        // libghostty's durable process-exit state instead.
        view.childExitCode = nil
        ghostty_surface_request_close(surface)

        waitUntil(timeout: 2.0) { reportedProcessAlive != nil }
        withExtendedLifetime(window) {}

        XCTAssertNotNil(reportedProcessAlive)
        XCTAssertEqual(reportedProcessAlive, false)
        XCTAssertEqual(
            view.childExitCode,
            0,
            "A normal status-zero close should carry its exit code through libghostty's close callback."
        )
    }

    func testControlASendsSOHToPTY() throws {
        try assertPTYReceives(
            readBytes: 1,
            characters: "\u{1}",
            charactersIgnoringModifiers: "a",
            modifiers: [.control],
            keyCode: 0,
            expectedRaw: "01",
            message: "Expected Ctrl-A to send 0x01 to the PTY"
        ) { view, size in self.hostInWindow(view, size: size) }
    }

    func testOptionDSendsMetaDToPTY() throws {
        try assertPTYReceives(
            readBytes: 2,
            characters: "d",
            charactersIgnoringModifiers: "d",
            modifiers: [.option],
            keyCode: 2,
            expectedRaw: "1b64",
            message: "Expected Option-D to send ESC d to the PTY"
        ) { view, size in self.hostInWindow(view, size: size) }
    }

    func testOptionDSendsMetaDToPTYWithPrintableOptionCharacter() throws {
        try assertPTYReceives(
            readBytes: 2,
            characters: "∂",
            charactersIgnoringModifiers: "d",
            modifiers: [.option],
            keyCode: 2,
            expectedRaw: "1b64",
            message: "Expected Option-D with a printable option character to send ESC d"
        ) { view, size in self.hostInWindow(view, size: size) }
    }

    func testInteractiveBashControlAMovesToBeginningOfLine() throws {
        try assertInteractiveControlAMovesToBeginningOfLine(
            configuration: makeInteractiveBashConfiguration(),
            hostMode: .appKit,
            commandNotFoundText: "Xecho: command not found"
        )
    }

    func testInteractiveBashControlAMovesToBeginningOfLineInSwiftUIHost() throws {
        try assertInteractiveControlAMovesToBeginningOfLine(
            configuration: makeInteractiveBashConfiguration(),
            hostMode: .swiftUI,
            eventRoute: .window,
            commandNotFoundText: "Xecho: command not found"
        )
    }

    func testInteractiveEmacsZshControlAMovesToBeginningOfLine() throws {
        try assertInteractiveControlAMovesToBeginningOfLine(
            configuration: makeInteractiveEmacsZshConfiguration(),
            hostMode: .appKit,
            eventRoute: .window,
            commandNotFoundText: "command not found: Xecho"
        )
    }

    func testInteractiveEmacsZshControlAMovesToBeginningOfLineInSwiftUIHost() throws {
        try assertInteractiveControlAMovesToBeginningOfLine(
            configuration: makeInteractiveEmacsZshConfiguration(),
            hostMode: .swiftUI,
            eventRoute: .window,
            commandNotFoundText: "command not found: Xecho"
        )
    }

    func testInteractiveEmacsZshControlAMovesToBeginningOfLineInSwiftUIHostViaApplicationDispatch(
    ) throws {
        try assertInteractiveControlAMovesToBeginningOfLine(
            configuration: makeInteractiveEmacsZshConfiguration(),
            hostMode: .swiftUI,
            eventRoute: .application,
            commandNotFoundText: "command not found: Xecho"
        )
    }

    func testDefaultShellControlAMovesToBeginningOfLineInGhosthubWorkspaceHost() throws {
        try assertInteractiveControlAMovesToBeginningOfLine(
            configuration: makeDefaultLocalZshConfiguration(),
            hostMode: .swiftUI,
            eventRoute: .application,
            commandNotFoundText: "command not found: Xecho",
            hostWindowBuilder: hostInGhosthubWorkspaceWindow
        )
    }

    func testDefaultShellControlEMovesToEndOfLineInGhosthubWorkspaceHost() throws {
        try assertInteractiveControlEMovesToEndOfLine(
            configuration: makeDefaultLocalZshConfiguration(),
            hostMode: .swiftUI,
            eventRoute: .application,
            commandNotFoundText: "command not found: abcX",
            hostWindowBuilder: hostInGhosthubWorkspaceWindow
        )
    }

    func testDirtyLauncherEnvironmentDoesNotBreakDefaultShellControlA() throws {
        try withTemporaryEnvironment([
            "EDITOR": "vim",
            "KITTY_INSTALLATION_DIR": "/Applications/kitty.app/Contents/Resources/kitty",
            "KITTY_PID": "2053",
            "KITTY_PUBLIC_KEY": "1:test",
            "KITTY_WINDOW_ID": "123",
            "VISUAL": "vim",
            "WINDOWID": "185",
            "__CFBundleIdentifier": "net.kovidgoyal.kitty",
            "TERMINFO": "/tmp/fake-terminfo",
        ]) {
            try assertInteractiveControlAMovesToBeginningOfLine(
                configuration: makeDefaultLocalZshConfiguration(),
                hostMode: .swiftUI,
                eventRoute: .application,
                commandNotFoundText: "command not found: Xecho"
            )
        }
    }

    func testDefaultShellUsesDefaultZshControlABindingInGhosthubWorkspaceHost() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: makeDefaultLocalZshConfiguration()
        )
        _ = hostInGhosthubWorkspaceWindow(
            view,
            size: CGSize(width: 1000, height: 700)
        )

        waitForViewportText("PROMPT> ", in: view, timeout: 10.0)
        // This command includes characters that `typeText` mixes between
        // async key events and direct text injection. Send it through a
        // single text path so the query stays ordered deterministically.
        sendText("bindkey '^A'", to: view)
        view.sendProgrammaticReturn()

        waitUntil(timeout: 10.0) {
            self.readViewportText(from: view).contains("\"^A\" beginning-of-line")
        }

        let contents = readViewportText(from: view)
        XCTAssertTrue(
            contents.contains("\"^A\" beginning-of-line"),
            "Expected Ghosthub's default shell startup to preserve zsh's standard Ctrl-A binding. Contents: \(contents)"
        )
    }

    func testInteractiveZshCommandLoadsUserZshrcInGhosthubWorkspaceHost() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: makeDefaultLocalZshConfiguration()
        )
        _ = hostInGhosthubWorkspaceWindow(
            view,
            size: CGSize(width: 1000, height: 700)
        )

        waitForViewportText("<ZSHRC_LOADED>", in: view, timeout: 10.0)
        let contents = readViewportText(from: view)
        XCTAssertTrue(
            contents.contains("<ZSHRC_LOADED>"),
            "Expected the explicit interactive zsh command to load the temporary .zshrc. Contents: \(contents)"
        )
    }

    func testDefaultLibghosttyShellIntegrationLoadsUserZshrc() throws {
        if ProcessInfo.processInfo.environment["RUNNER_ENVIRONMENT"]
            == "self-hosted" {
            throw XCTSkip(
                "The self-hosted runner service account cannot start macOS's account-login shell."
            )
        }

        let (pipeline, _) = makeIsolatedSurfacePipeline()
        let runtime = LibghosttyRuntime(pipeline: pipeline)
        Self.transientRuntimes.append(runtime)
        let appHandle = try requireAppHandle(from: runtime)

        let homeDirectory = makeTemporaryDirectory()
        let zshrc = homeDirectory.appendingPathComponent(".zshrc", isDirectory: false)
        try """
        print -r -- "<DEFAULT_ZSHRC_LOADED>"
        PROMPT='PROMPT> '
        RPROMPT=''
        """.write(to: zshrc, atomically: true, encoding: .utf8)

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                environmentVariables: [
                    "HOME": homeDirectory.path,
                    "SHELL": "/bin/zsh",
                    "ZDOTDIR": homeDirectory.path,
                ]
            )
        )
        _ = hostInGhosthubWorkspaceWindow(
            view,
            size: CGSize(width: 1000, height: 700)
        )

        waitForViewportText("<DEFAULT_ZSHRC_LOADED>", in: view, timeout: 10.0)
        let contents = readViewportText(from: view)
        XCTAssertTrue(
            contents.contains("<DEFAULT_ZSHRC_LOADED>"),
            "Expected Ghosthub's default shell path to load the user's .zshrc via shell integration. Contents: \(contents)"
        )
    }

    func testForeignLauncherVariablesDoNotLeakIntoChildShell() throws {
        let appHandle = try requireAppHandle()

        withTemporaryEnvironment([
            "EDITOR": "vim",
            "KITTY_WINDOW_ID": "123",
            "KITTY_PID": "456",
            "VISUAL": "vim",
            "WINDOWID": "185",
            "__CFBundleIdentifier": "net.kovidgoyal.kitty",
        ]) {
            let scriptURL = makeEnvironmentProbeScript([
                "EDITOR",
                "KITTY_WINDOW_ID",
                "KITTY_PID",
                "VISUAL",
                "WINDOWID",
                "__CFBundleIdentifier",
                "TERM_PROGRAM",
            ])
            let view = makeSurface(
                app: appHandle,
                configuration: TerminalSurfaceConfiguration(
                    command: "python3 '\(scriptURL.path)'"
                )
            )
            _ = hostInWindow(view, size: CGSize(width: 800, height: 600))
            waitForViewportText("TERM_PROGRAM=", in: view)

            let contents = readViewportText(from: view)
            let lines = contents
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            let keyValuePairs: [(String, String)] = lines.compactMap { line in
                guard let split = line.firstIndex(of: "=") else { return nil }
                return (
                    String(line[..<split]),
                    String(line[line.index(after: split)...])
                )
            }
            let values = Dictionary(
                uniqueKeysWithValues: keyValuePairs.map { (
                    $0.0,
                    $0.1.trimmingCharacters(in: .whitespaces)
                ) }
            )

            XCTAssertEqual(values["EDITOR"], "")
            XCTAssertEqual(values["KITTY_WINDOW_ID"], "")
            XCTAssertEqual(values["KITTY_PID"], "")
            XCTAssertEqual(values["VISUAL"], "")
            XCTAssertEqual(values["WINDOWID"], "")
            XCTAssertEqual(values["__CFBundleIdentifier"], "")
            XCTAssertTrue(
                values["TERM_PROGRAM"] == "ghosthub",
                "Expected Ghosthub to publish its own TERM_PROGRAM marker. Contents: \(contents)"
            )
        }
    }

    func testSurfacePublishesChildProcessIDAfterLaunchingShell() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 -c 'import time; time.sleep(10)'"
            )
        )
        _ = hostInWindow(view, size: CGSize(width: 800, height: 600))

        waitUntil(timeout: 5.0) {
            view.childProcessID != nil
        }

        XCTAssertNotNil(
            view.childProcessID,
            "Expected the libghostty surface to expose a live child PID for resource attribution."
        )
    }

    func testOptionDSendsMetaDToPTYViaApplicationDispatch() throws {
        try assertPTYReceives(
            readBytes: 2,
            characters: "d",
            charactersIgnoringModifiers: "d",
            modifiers: [.option],
            keyCode: 2,
            route: .application,
            expectedRaw: "1b64",
            message: "Expected Option-D to send ESC d through NSApp.sendEvent"
        ) { view, size in
            self.hostInSwiftUIWindow(view, size: size)
        }
    }

    func testControlASendsSOHToPTYInGhosthubWorkspaceHost() throws {
        try assertPTYReceives(
            readBytes: 1,
            characters: "\u{1}",
            charactersIgnoringModifiers: "a",
            modifiers: [.control],
            keyCode: 0,
            route: .application,
            expectedRaw: "01",
            message: "Expected Ctrl-A to send 0x01 through the full Ghosthub workspace host"
        ) { view, _ in
            self.hostInGhosthubWorkspaceWindow(
                view,
                size: CGSize(width: 1000, height: 700)
            )
        }
    }

    func testNativeTmuxWorkspaceSwitchesRenderedSurfaceWhenSelectionChanges()
        throws {
        final class SelectionModel: ObservableObject {
            @Published var selection: WorkspaceSelection
            @Published var columnVisibility: NavigationSplitViewVisibility = .detailOnly
            @Published var isCommandPalettePresented = false
            @Published var activeTmuxSession:
                WorkspaceTmuxSessionSelection?

            init(selection: WorkspaceSelection) {
                self.selection = selection
            }
        }

        struct RootHarness: View {
            @ObservedObject var model: SelectionModel
            let snapshot: WorkspaceSnapshot
            let surfacesBySession: [String: TerminalSurfaceView]

            var body: some View {
                RootView(
                    display: WorkspaceDisplayState(
                        snapshot: snapshot,
                        activeTmuxSession: model.activeTmuxSession
                    ),
                    content: ContentBuilders(
                        tmuxSessionContentBuilder: { _, sessionName, _, _ in
                            guard let surfaceView =
                                surfacesBySession[sessionName]
                            else { return nil }
                            return AnyView(
                                TerminalSurfaceSwiftUIView(
                                    surfaceView: surfaceView
                                )
                            )
                        }
                    ),
                    handlers: InteractionHandlers(
                        openTmuxSession: { session in
                            model.activeTmuxSession = session
                        },
                        closeTmuxSession: { session in
                            guard model.activeTmuxSession == session else {
                                return
                            }
                            model.activeTmuxSession = nil
                        }
                    ),
                    selection: Binding(
                        get: { model.selection },
                        set: { model.selection = $0 }
                    ),
                    columnVisibility: Binding(
                        get: { model.columnVisibility },
                        set: { model.columnVisibility = $0 }
                    ),
                    isCommandPalettePresented: Binding(
                        get: {
                            model.isCommandPalettePresented
                        },
                        set: {
                            model.isCommandPalettePresented = $0
                        }
                    )
                )
            }
        }

        let appHandle = try requireAppHandle()

        let hostID = UUID()
        let projectID = UUID()
        let firstWorktreeID = UUID()
        let secondWorktreeID = UUID()
        let snapshot = WorkspaceSnapshot(
            hosts: [
                HostSummary(
                    id: hostID,
                    name: "This Mac",
                    kind: .selfHost,
                    platform: .macOS
                ),
            ],
            projects: [
                ProjectSummary(
                    id: projectID,
                    hostID: hostID,
                    name: "ghosthub",
                    rootPath: "/tmp/ghosthub"
                ),
            ],
            worktrees: [
                WorktreeSummary(
                    id: firstWorktreeID,
                    hostID: hostID,
                    projectID: projectID,
                    name: "root",
                    path: "/tmp/ghosthub",
                    branch: "main",
                    tmuxSessionName: "root"
                ),
                WorktreeSummary(
                    id: secondWorktreeID,
                    hostID: hostID,
                    projectID: projectID,
                    name: "feature",
                    path: "/tmp/ghosthub-feature",
                    branch: "feature/split",
                    tmuxSessionName: "feature"
                ),
            ]
        )

        let surfaceA = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let surfaceB = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let surfacesBySession = [
            "root": surfaceA,
            "feature": surfaceB,
        ]

        let model = SelectionModel(
            selection: WorkspaceSelection(
                selectedHostID: hostID,
                selectedProjectID: projectID,
                selectedWorktreeID: firstWorktreeID
            )
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 1000, height: 700)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(
            rootView: RootHarness(
                model: model,
                snapshot: snapshot,
                surfacesBySession: surfacesBySession
            )
        )
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertTrue(descendantViews(in: window.contentView).contains(surfaceA))
        XCTAssertFalse(descendantViews(in: window.contentView).contains(surfaceB))

        model.selection = WorkspaceSelection(
            selectedHostID: hostID,
            selectedProjectID: projectID,
            selectedWorktreeID: secondWorktreeID
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertFalse(descendantViews(in: window.contentView).contains(surfaceA))
        XCTAssertTrue(descendantViews(in: window.contentView).contains(surfaceB))
    }

    func testNonKeyWindowCannotMarkTerminalFocused() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: CGSize(width: 960, height: 640)
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        window.contentView = view
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.requestKeyboardFocus()
        XCTAssertTrue(window.makeFirstResponder(view))

        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(
            view.focused,
            "A terminal in a background window must reject every positive focus transition."
        )
    }

    func testWindowResigningKeyClearsTerminalFocus() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        view.focusDidChange(true)

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        XCTAssertFalse(
            view.focused,
            "A terminal must lose libghostty focus when its window resigns key status."
        )
    }

    func testDetachingViewClearsFocusState() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)
        waitUntil(timeout: 2.0) { view.window === window && view.focused }

        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(view.window)
        XCTAssertFalse(
            view.focused,
            "Detached terminal surfaces must clear focus so cached worktrees cannot intercept command-key shortcuts."
        )
    }

    func testInitialAttachMarksVisibleWindowAsUnoccluded() throws {
        let appHandle = try requireAppHandle()
        let previousSetter = TerminalSurfaceView.occlusionSetter
        var occlusionStates: [Bool] = []
        TerminalSurfaceView.occlusionSetter = { _, visible in
            occlusionStates.append(visible)
        }
        defer {
            TerminalSurfaceView.occlusionSetter = previousSetter
        }

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)

        waitUntil(timeout: 2.0) {
            view.window === window && !occlusionStates.isEmpty
        }

        XCTAssertEqual(
            occlusionStates.first,
            true,
            "Attaching a live surface into a visible key window should mark it unoccluded immediately."
        )
        XCTAssertEqual(
            occlusionStates.last,
            true,
            "A newly attached visible surface must stay renderable after the first attach sync."
        )
    }

    func testInitialSwiftUIAttachAppliesCurrentSurfaceSize() throws {
        let appHandle = try requireAppHandle()
        let previousSetter = TerminalSurfaceView.sizeSetter
        var appliedSizes: [(width: UInt32, height: UInt32)] = []
        TerminalSurfaceView.sizeSetter = { surface, width, height in
            appliedSizes.append((width, height))
            ghostty_surface_set_size(surface, width, height)
        }
        defer {
            TerminalSurfaceView.sizeSetter = previousSetter
        }

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInSwiftUIWindow(
            view,
            size: CGSize(width: 720, height: 460)
        )
        defer { window.orderOut(nil) }

        waitUntil(timeout: 2.0) {
            view.window === window && !appliedSizes.isEmpty
        }

        let expectedSize = view.convertToBacking(view.bounds.size)
        XCTAssertEqual(
            appliedSizes.last?.width,
            UInt32(expectedSize.width)
        )
        XCTAssertEqual(
            appliedSizes.last?.height,
            UInt32(expectedSize.height)
        )
    }

    func testLiveWindowResizeAppliesOnlyTheFinalSurfaceSize() throws {
        let appHandle = try requireAppHandle()
        let previousSetter = TerminalSurfaceView.sizeSetter
        var appliedSizes: [(width: UInt32, height: UInt32)] = []
        TerminalSurfaceView.sizeSetter = { surface, width, height in
            appliedSizes.append((width, height))
            ghostty_surface_set_size(surface, width, height)
        }
        defer {
            TerminalSurfaceView.sizeSetter = previousSetter
        }

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        appliedSizes.removeAll()

        view.viewWillStartLiveResize()
        view.setFrameSize(NSSize(width: 700, height: 450))
        view.setFrameSize(NSSize(width: 760, height: 480))
        view.viewDidEndLiveResize()

        let expectedSize = view.convertToBacking(view.bounds.size)
        XCTAssertEqual(
            appliedSizes.count,
            1,
            "A live window drag must notify the PTY only after the final size is known."
        )
        XCTAssertEqual(appliedSizes.last?.width, UInt32(expectedSize.width))
        XCTAssertEqual(appliedSizes.last?.height, UInt32(expectedSize.height))
    }

    func testOversizedSurfaceResizeNeverReachesLibghostty() throws {
        let appHandle = try requireAppHandle()
        let previousSetter = TerminalSurfaceView.sizeSetter
        var appliedSizes: [(width: UInt32, height: UInt32)] = []
        TerminalSurfaceView.sizeSetter = { surface, width, height in
            appliedSizes.append((width, height))
            ghostty_surface_set_size(surface, width, height)
        }
        defer {
            TerminalSurfaceView.sizeSetter = previousSetter
        }

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        appliedSizes.removeAll()

        view.sizeDidChange(CGSize(
            width: SurfacePixelSize.maximumDimension + 1,
            height: 480
        ))

        XCTAssertTrue(
            appliedSizes.isEmpty,
            "A size that can overflow libghostty's grid must be rejected before its C boundary."
        )
    }

    func testPresentationResizeAppliesOnlyTheFinalSurfaceSize() throws {
        let appHandle = try requireAppHandle()
        let previousSetter = TerminalSurfaceView.sizeSetter
        var appliedSizes: [(width: UInt32, height: UInt32)] = []
        TerminalSurfaceView.sizeSetter = { surface, width, height in
            appliedSizes.append((width, height))
            ghostty_surface_set_size(surface, width, height)
        }
        defer {
            TerminalSurfaceView.sizeSetter = previousSetter
        }

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        appliedSizes.removeAll()

        view.setPresentationResizeDeferred(true)
        view.setFrameSize(NSSize(width: 700, height: 450))
        view.setFrameSize(NSSize(width: 760, height: 480))

        XCTAssertTrue(
            appliedSizes.isEmpty,
            "A presentation transition must keep the terminal grid stable."
        )

        view.setPresentationResizeDeferred(false)

        let expectedSize = view.convertToBacking(view.bounds.size)
        XCTAssertEqual(
            appliedSizes.count,
            1,
            "Ending a presentation transition must apply only its final size."
        )
        XCTAssertEqual(appliedSizes.last?.width, UInt32(expectedSize.width))
        XCTAssertEqual(appliedSizes.last?.height, UInt32(expectedSize.height))
    }

    func testPresentationResizeWaitsForOverlappingLiveResize() throws {
        let appHandle = try requireAppHandle()
        let previousSetter = TerminalSurfaceView.sizeSetter
        var appliedSizes: [(width: UInt32, height: UInt32)] = []
        TerminalSurfaceView.sizeSetter = { surface, width, height in
            appliedSizes.append((width, height))
            ghostty_surface_set_size(surface, width, height)
        }
        defer {
            TerminalSurfaceView.sizeSetter = previousSetter
        }

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)
        defer { window.orderOut(nil) }
        appliedSizes.removeAll()

        view.viewWillStartLiveResize()
        view.setPresentationResizeDeferred(true)
        view.setFrameSize(NSSize(width: 760, height: 480))
        view.setPresentationResizeDeferred(false)

        XCTAssertTrue(
            appliedSizes.isEmpty,
            "Ending one resize transition must not flush another active transition."
        )

        view.viewDidEndLiveResize()

        XCTAssertEqual(appliedSizes.count, 1)
    }

    func testDetachingViewMarksSurfaceOccluded() throws {
        let appHandle = try requireAppHandle()
        let previousSetter = TerminalSurfaceView.occlusionSetter
        var occlusionStates: [Bool] = []
        TerminalSurfaceView.occlusionSetter = { _, visible in
            occlusionStates.append(visible)
        }
        defer {
            TerminalSurfaceView.occlusionSetter = previousSetter
        }

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)
        waitUntil(timeout: 2.0) {
            view.window === window && view.focused && occlusionStates.contains(true)
        }

        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        waitUntil(timeout: 2.0) {
            view.window == nil && occlusionStates.last == false
        }

        XCTAssertEqual(
            occlusionStates.last,
            false,
            "Detaching a live surface from its window must mark it occluded so libghostty stops rendering."
        )
    }

    func testOptionDSendsMetaDToPTYInGhosthubWorkspaceHost() throws {
        try assertPTYReceives(
            readBytes: 2,
            characters: "d",
            charactersIgnoringModifiers: "d",
            modifiers: [.option],
            keyCode: 2,
            route: .application,
            expectedRaw: "1b64",
            message: "Expected Option-D to send ESC d through the full Ghosthub workspace host"
        ) { view, _ in
            self.hostInGhosthubWorkspaceWindow(
                view,
                size: CGSize(width: 1000, height: 700)
            )
        }
    }

    func testControlESendsENQToPTYInGhosthubWorkspaceHost() throws {
        try assertPTYReceives(
            readBytes: 1,
            characters: "\u{5}",
            charactersIgnoringModifiers: "e",
            modifiers: [.control],
            keyCode: 14,
            route: .application,
            expectedRaw: "05",
            message: "Expected Ctrl-E to send 0x05 through the full Ghosthub workspace host"
        ) { view, _ in
            self.hostInGhosthubWorkspaceWindow(
                view,
                size: CGSize(width: 1000, height: 700)
            )
        }
    }

    func testUnboundCmdShiftScreenshotKeysPassThrough() throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view)

        let screenshotKeys: [(keyCode: UInt16, chars: String, rawChars: String, label: String)] = [
            (20, "#", "3", "Cmd+Shift+3"),
            (21, "$", "4", "Cmd+Shift+4"),
            (23, "%", "5", "Cmd+Shift+5"),
        ]

        for key in screenshotKeys {
            let event = makeKeyEvent(
                characters: key.chars,
                charactersIgnoringModifiers: key.rawChars,
                modifiers: [.command, .shift],
                keyCode: key.keyCode,
                windowNumber: window.windowNumber
            )

            XCTAssertFalse(
                view.performKeyEquivalent(with: event),
                "\(key.label) must pass through to the system for screenshot handling."
            )
        }
    }

    // MARK: - tmuxPaneInputSink wiring

    func testTmuxPaneInputSinkReceivesPlainKeyAndSkipsLocalCore() throws {
        let appHandle = try requireAppHandle()
        let scriptURL = makeRawInputProbeScript(readBytes: 1)
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        var sunkData: [Data] = []
        view.tmuxPaneInputSink = { sunkData.append($0) }
        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)

        dispatch(
            makeKeyEvent(
                characters: "a",
                charactersIgnoringModifiers: "a",
                modifiers: [],
                keyCode: 0,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .window
        )
        settleInputPipeline()

        XCTAssertEqual(
            sunkData,
            [Data("a".utf8)],
            "A pane-routed plain key should be encoded and forwarded to the tmux pane sink."
        )
        XCTAssertFalse(
            readViewportText(from: view).contains("<RAW:"),
            "Pane-routed keys must never reach the local core's PTY."
        )
    }

    func testTmuxPaneInputSinkForwardsIMETextCommittedWithReturn() throws {
        let appHandle = try requireAppHandle()
        var view: TerminalSurfaceView!
        var interpretation = 0
        view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(),
            keyEventInterpreter: { _ in
                defer { interpretation += 1 }
                if interpretation == 0 {
                    view.setMarkedText(
                        "´",
                        selectedRange: NSRange(location: 1, length: 0),
                        replacementRange: NSRange(location: NSNotFound, length: 0)
                    )
                } else {
                    view.insertTextForTesting("é")
                }
            }
        )
        var sunkData: [Data] = []
        view.tmuxPaneInputSink = { sunkData.append($0) }
        let window = hostInWindow(view)

        window.sendEvent(makeKeyEvent(
            characters: "e",
            charactersIgnoringModifiers: "e",
            modifiers: [.option],
            keyCode: 14,
            windowNumber: window.windowNumber
        ))
        settleInputPipeline()
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(
            sunkData.isEmpty,
            "An in-progress IME/dead-key event must not emit pane bytes."
        )

        window.sendEvent(makeKeyEvent(
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            modifiers: [],
            keyCode: 36,
            windowNumber: window.windowNumber
        ))
        settleInputPipeline()

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(
            sunkData,
            [Data("é".utf8)],
            "Return must commit the IME payload without replacing it with CR."
        )
    }

    /// Pane-routed input preserves the same Meta-D bytes as libghostty's local
    /// encoder when macos-option-as-alt translates Option-D to plain "d".
    func testTmuxPaneInputSinkOptionDSendsMetaEscape() throws {
        let appHandle = try requireAppHandle()
        let scriptURL = makeRawInputProbeScript(readBytes: 1)
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        var sunkData: [Data] = []
        view.tmuxPaneInputSink = { sunkData.append($0) }
        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)

        dispatch(
            makeKeyEvent(
                characters: "∂",
                charactersIgnoringModifiers: "d",
                modifiers: [.option],
                keyCode: 2,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .window
        )
        settleInputPipeline()

        XCTAssertEqual(
            sunkData,
            [Data([0x1b, 0x64])],
            "Pane-routed Option-D must preserve its Meta escape prefix."
        )
        XCTAssertFalse(
            readViewportText(from: view).contains("<RAW:"),
            "Pane-routed keys must never reach the local core's PTY."
        )
    }

    /// Ctrl-Enter must remain distinguishable from Enter when pane input is
    /// routed through tmux. CSI u carries the Control modifier without
    /// leaking the event to the silent local child.
    func testTmuxPaneInputSinkCtrlEnterSendsCSIU() throws {
        let appHandle = try requireAppHandle()
        let scriptURL = makeRawInputProbeScript(readBytes: 1)
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        var sunkData: [Data] = []
        view.tmuxPaneInputSink = { sunkData.append($0) }
        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)

        dispatch(
            makeKeyEvent(
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                modifiers: [.control],
                keyCode: 36,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .window
        )
        settleInputPipeline()

        XCTAssertEqual(
            sunkData,
            [Data("\u{1b}[13;5u".utf8)],
            "Pane-routed Ctrl-Enter must preserve Control via CSI u."
        )
        XCTAssertFalse(
            readViewportText(from: view).contains("<RAW:"),
            "Pane-routed keys must never reach the local core's PTY."
        )
    }

    /// macOS already supplies the canonical control byte for a shifted
    /// alphabetic chord. Preserve it so standard terminal bindings work.
    func testTmuxPaneInputSinkCtrlShiftLetterSendsControlByte() throws {
        let appHandle = try requireAppHandle()
        let scriptURL = makeRawInputProbeScript(readBytes: 1)
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        var sunkData: [Data] = []
        view.tmuxPaneInputSink = { sunkData.append($0) }
        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)

        dispatch(
            makeKeyEvent(
                characters: "\u{12}",
                charactersIgnoringModifiers: "R",
                modifiers: [.control, .shift],
                keyCode: 15,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .window
        )
        settleInputPipeline()

        XCTAssertEqual(
            sunkData,
            [Data([0x12])],
            "Pane-routed Ctrl-Shift-R must preserve its control byte."
        )
        XCTAssertFalse(
            readViewportText(from: view).contains("<RAW:"),
            "Pane-routed keys must never reach the local core's PTY."
        )
    }

    /// Regression coverage for the dead-code paste chokepoint: fantastty's
    /// Cmd+V reaches its paste override through a menu re-dispatch inside
    /// performKeyEquivalent, but Ghosthub's local NSEvent monitor consumes
    /// Cmd+V and calls keyDown directly whenever the shortcut has a libghostty
    /// key binding (paste is bound by default) — so performKeyEquivalent
    /// never runs for it. This test dispatches through `.application`
    /// specifically to exercise that local-monitor precedence; it fails if
    /// the routing chokepoint lives anywhere performKeyEquivalent would run
    /// but the local monitor's keyDown short-circuit does not.
    func testPasteboardTmuxPaneInputSinkReceivesPasteOnCmdVViaApplicationDispatch() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        var sunkData: [Data] = []
        var pastedData: [Data] = []
        view.tmuxPaneInputSink = { sunkData.append($0) }
        view.tmuxPanePasteSink = { pastedData.append($0) }
        let window = hostInWindow(view, requiresActiveApplication: true)
        waitUntil(timeout: 2.0) {
            view.window === window && view.focused && window.isKeyWindow
        }
        guard window.isKeyWindow else {
            throw XCTSkip(
                "Test requires window server"
                    + " - skipping in headless environment"
            )
        }

        pasteboard.clearContents()
        pasteboard.setString("pane-routed-paste", forType: .string)

        dispatch(
            makeKeyEvent(
                characters: "v",
                charactersIgnoringModifiers: "v",
                modifiers: [.command],
                keyCode: 9,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .application
        )
        settleInputPipeline()

        XCTAssertEqual(
            pastedData,
            [Data("pane-routed-paste".utf8)],
            "Cmd+V must use the tmux paste path when one is attached."
        )
        XCTAssertTrue(sunkData.isEmpty, "Paste must not use raw send-keys input.")
    }

    func testRemoteImagePasteConsumesCtrlVBeforeItReachesThePTY() throws {
        let appHandle = try requireAppHandle()
        let scriptURL = makeRawInputProbeScript(readBytes: 1)
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        var receivedImage: TerminalClipboardImage?
        view.remoteImagePasteHandler = { receivedImage = $0 }
        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)
        pasteboard.setData(png, forType: .png)

        dispatch(
            makeKeyEvent(
                characters: "\u{16}",
                charactersIgnoringModifiers: "v",
                modifiers: [.control],
                keyCode: 9,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .window
        )
        typeText("x", into: view, window: window)

        waitForViewportText("<RAW:78>", in: view)
        XCTAssertEqual(receivedImage?.pngData, png)
    }

    func testRemoteCtrlVWithoutImageReachesThePTY() throws {
        let appHandle = try requireAppHandle()
        let scriptURL = makeRawInputProbeScript(readBytes: 1)
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        var receivedImage: TerminalClipboardImage?
        view.remoteImagePasteHandler = { receivedImage = $0 }
        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)
        pasteboard.clearContents()
        pasteboard.setString("ordinary text", forType: .string)

        dispatch(
            makeKeyEvent(
                characters: "\u{16}",
                charactersIgnoringModifiers: "v",
                modifiers: [.control],
                keyCode: 9,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .window
        )

        waitForViewportText("<RAW:16>", in: view)
        XCTAssertNil(receivedImage)
    }

    func testProgrammaticImagePathUsesBracketedPaste() throws {
        let appHandle = try requireAppHandle()
        let path = "/home/dev/.ghosthub/paste-images/paste-test.png"
        let expectedData = Data("\u{1b}[200~\(path)\u{1b}[201~".utf8)
        let expectedRaw = expectedData
            .map { String(format: "%02x", $0) }
            .joined()
        let scriptURL = makeBracketedPasteProbeScript(
            readBytes: expectedData.count
        )
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        view.blocksClipboardReads = true
        _ = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)

        XCTAssertTrue(view.pasteProgrammaticInput(path))

        waitForViewportText("<RAW:\(expectedRaw)>", in: view)
    }

    /// Regression coverage for roborev finding 1332: `isPasteShortcut`
    /// previously required device-independent flags to equal exactly
    /// `.command`, so Caps Lock being active (which contributes
    /// `.capsLock` to `deviceIndependentFlagsMask`) made the comparison
    /// fail and Cmd+V fell through to the local core instead of routing to
    /// the attached tmux pane sink.
    func testPasteboardTmuxPaneInputSinkReceivesPasteOnCmdVWithCapsLockActive() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        var sunkData: [Data] = []
        var pastedData: [Data] = []
        view.tmuxPaneInputSink = { sunkData.append($0) }
        view.tmuxPanePasteSink = { pastedData.append($0) }
        let window = hostInWindow(view, requiresActiveApplication: true)
        waitUntil(timeout: 2.0) {
            view.window === window && view.focused && window.isKeyWindow
        }
        guard window.isKeyWindow else {
            throw XCTSkip(
                "Test requires window server"
                    + " - skipping in headless environment"
            )
        }

        pasteboard.clearContents()
        pasteboard.setString("caps-lock-pane-routed-paste", forType: .string)

        dispatch(
            makeKeyEvent(
                characters: "v",
                charactersIgnoringModifiers: "v",
                modifiers: [.command, .capsLock],
                keyCode: 9,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .application
        )
        settleInputPipeline()

        XCTAssertEqual(
            pastedData,
            [Data("caps-lock-pane-routed-paste".utf8)],
            "Cmd+V must route to the tmux pane sink even when Caps Lock is active."
        )
        XCTAssertTrue(sunkData.isEmpty, "Paste must not use raw send-keys input.")
    }

    func testCmdVWithoutPaneSinkStaysLocal() throws {
        let appHandle = try requireAppHandle()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        let window = hostInWindow(view, requiresActiveApplication: true)
        waitUntil(timeout: 2.0) {
            view.window === window && view.focused && window.isKeyWindow
        }
        guard window.isKeyWindow else {
            throw XCTSkip(
                "Test requires window server"
                    + " - skipping in headless environment"
            )
        }

        let event = makeKeyEvent(
            characters: "v",
            charactersIgnoringModifiers: "v",
            modifiers: [.command],
            keyCode: 9,
            windowNumber: window.windowNumber
        )

        let localResult = view.processLocalEventForTesting(event)

        XCTAssertNil(
            localResult,
            "Cmd-V must still be consumed locally by the terminal when no tmux pane sink is attached."
        )
    }

    func testPasteboardUnsafeCmdVRequiresConfirmationBeforeRemotePaste() throws {
        let runtime = try runtimeWithClipboardReadsAllowed()
        let appHandle = try requireAppHandle(from: runtime)
        let pastedText = "remote-paste\n"
        // libghostty's paste encoder normalizes a line feed to the terminal's
        // carriage-return input outside bracketed-paste mode.
        let expectedRaw = Data("remote-paste\r".utf8)
            .map { String(format: "%02x", $0) }
            .joined()
        let scriptURL = makeRawInputProbeScript(
            readBytes: pastedText.utf8.count
        )
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        view.blocksClipboardReads = true
        let previousPresenter =
            TerminalSurfaceView.clipboardConfirmationPresenter
        var confirmation: ((Bool) -> Void)?
        var confirmationContents: String?
        var confirmationRequest: ghostty_clipboard_request_e?
        TerminalSurfaceView.clipboardConfirmationPresenter = {
            _, contents, request, completion in
            confirmationContents = contents
            confirmationRequest = request
            confirmation = completion
        }
        defer {
            TerminalSurfaceView.clipboardConfirmationPresenter =
                previousPresenter
        }
        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)

        pasteboard.clearContents()
        pasteboard.setString(pastedText, forType: .string)

        dispatch(
            makeKeyEvent(
                characters: "v",
                charactersIgnoringModifiers: "v",
                modifiers: [.command],
                keyCode: 9,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .application
        )

        waitUntil(timeout: 2.0) { confirmation != nil }
        XCTAssertEqual(confirmationContents, pastedText)
        XCTAssertEqual(
            confirmationRequest,
            GHOSTTY_CLIPBOARD_REQUEST_PASTE
        )
        XCTAssertFalse(
            readViewportText(from: view).contains("<RAW:"),
            "Unsafe multiline paste must not reach the PTY before approval."
        )

        confirmation?(true)
        waitForViewportText("<RAW:\(expectedRaw)>", in: view)
        let contents = readViewportText(from: view)
        XCTAssertTrue(
            contents.contains("<RAW:\(expectedRaw)>"),
            "Approved Cmd-V must paste through a remote native tmux surface."
                + " Contents: \(contents)"
        )
    }

    func testPasteboardCmdVPreservesBracketedPasteFramingOnRemoteSurface() throws {
        let runtime = try runtimeWithClipboardReadsAllowed()
        let appHandle = try requireAppHandle(from: runtime)
        let pastedText = "first\nsecond"
        let expectedData = Data(
            "\u{1b}[200~\(pastedText)\u{1b}[201~".utf8
        )
        let expectedRaw = expectedData
            .map { String(format: "%02x", $0) }
            .joined()
        let scriptURL = makeBracketedPasteProbeScript(
            readBytes: expectedData.count
        )
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        view.blocksClipboardReads = true

        let previousPresenter =
            TerminalSurfaceView.clipboardConfirmationPresenter
        var confirmationRequests = 0
        TerminalSurfaceView.clipboardConfirmationPresenter = {
            _, _, _, _ in confirmationRequests += 1
        }
        defer {
            TerminalSurfaceView.clipboardConfirmationPresenter =
                previousPresenter
        }

        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)

        pasteboard.clearContents()
        pasteboard.setString(pastedText, forType: .string)

        dispatch(
            makeKeyEvent(
                characters: "v",
                charactersIgnoringModifiers: "v",
                modifiers: [.command],
                keyCode: 9,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: .application
        )

        waitForViewportText("<RAW:\(expectedRaw)>", in: view)
        XCTAssertEqual(confirmationRequests, 0)
        XCTAssertTrue(
            readViewportText(from: view).contains("<RAW:\(expectedRaw)>"),
            "Cmd-V must retain libghostty's bracketed-paste fenceposts."
        )
    }

    func testPasteboardRemotePasteFollowsReboundSemanticShortcut() throws {
        let runtime = try runtimeWithTerminalConfig(
            """
            clipboard-read = allow
            keybind = super+v=unbind
            keybind = super+shift+v=paste_from_clipboard
            """
        )
        let appHandle = try requireAppHandle(from: runtime)
        let pastedText = "rebound paste"
        let expectedData = Data(pastedText.utf8)
        let expectedRaw = expectedData
            .map { String(format: "%02x", $0) }
            .joined()
        let scriptURL = makeRawInputProbeScript(
            readBytes: expectedData.count
        )
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        view.blocksClipboardReads = true
        let window = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)

        pasteboard.clearContents()
        pasteboard.setString(pastedText, forType: .string)

        let oldShortcut = makeKeyEvent(
            characters: "v",
            charactersIgnoringModifiers: "v",
            modifiers: [.command],
            keyCode: 9,
            windowNumber: window.windowNumber
        )
        let reboundShortcut = makeKeyEvent(
            characters: "V",
            charactersIgnoringModifiers: "v",
            modifiers: [.command, .shift],
            keyCode: 9,
            windowNumber: window.windowNumber
        )

        XCTAssertFalse(view.hasLibghosttyKeyBinding(for: oldShortcut))
        XCTAssertTrue(view.hasLibghosttyKeyBinding(for: reboundShortcut))

        dispatch(oldShortcut, to: window, route: .application)
        settleInputPipeline()
        XCTAssertFalse(
            readViewportText(from: view).contains("<RAW:"),
            "An unbound Cmd-V must not read or paste clipboard contents."
        )

        dispatch(reboundShortcut, to: window, route: .application)

        waitForViewportText("<RAW:\(expectedRaw)>", in: view)
        XCTAssertTrue(
            readViewportText(from: view).contains("<RAW:\(expectedRaw)>"),
            "Remote paste must follow libghostty's configured binding."
        )
    }

    func testPasteboardClipboardIsolatedSurfaceReturnsNoDataToOSC52ReadWhenAllowedByConfig() throws {
        let runtime = try runtimeWithClipboardReadsAllowed()
        let appHandle = try requireAppHandle(from: runtime)
        let scriptURL = makeOSC52ReadProbeScript()
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        view.blocksClipboardReads = true

        pasteboard.clearContents()
        pasteboard.setString("local-secret", forType: .string)

        _ = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForProbeReady(in: view)
        let emptyOSC52Response = "<OSC52:1b5d35323b633b1b5c>"
        waitForViewportText(emptyOSC52Response, in: view)

        let contents = readViewportText(from: view)
        XCTAssertTrue(
            contents.contains(emptyOSC52Response),
            "Remote OSC 52 reads must receive an empty clipboard response."
                + " Contents: \(contents)"
        )
        XCTAssertFalse(
            contents.contains(
                Data("local-secret".utf8).base64EncodedString()
            ),
            "Remote OSC 52 reads must never receive local clipboard data."
        )
    }

    func testRemoteSurfaceWritesOSC52CopyToPasteboard() throws {
        let runtime = try runtimeWithTerminalConfig(
            "clipboard-write = allow\n"
        )
        let appHandle = try requireAppHandle(from: runtime)
        let copiedText = "remote tmux copy"
        let encodedText = Data(copiedText.utf8).base64EncodedString()
        let scriptURL = makeExecutableScript(
            """
            #!/usr/bin/env python3
            import os

            os.write(1, b"\\x1b]52;c;\(encodedText)\\x07")
            print("<WROTE>", flush=True)
            """
        )
        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration(
                command: "python3 '\(scriptURL.path)'"
            )
        )
        view.blocksClipboardReads = true
        var diagnostics: [
            LibghosttyRuntime.OSC52ClipboardWriteDiagnostic
        ] = []
        LibghosttyRuntime.osc52ClipboardWriteDiagnosticObserver = {
            diagnostics.append($0)
        }

        pasteboard.clearContents()

        _ = hostInWindow(view)
        waitUntil(timeout: 5.0) { view.error == nil }
        waitForViewportText("<WROTE>", in: view)
        waitUntil(timeout: 3.0) {
            self.pasteboard.string(forType: .string) == copiedText
        }

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            copiedText,
            "OSC 52 copy from a remote surface must reach the Mac clipboard."
        )
        XCTAssertEqual(
            diagnostics.last,
            .written(
                entryCount: 1,
                byteCount: copiedText.utf8.count
            )
        )
    }

    func testOSC52ClipboardDiagnosticReportsPasteboardRejection() {
        pasteboard.acceptsWrites = false
        let copiedText = "clipboard write"

        let diagnostic = LibghosttyRuntime.writeClipboardEntries(
            [
                .init(mime: "text/plain", data: copiedText),
                .init(
                    mime: LibghosttyRuntime.osc52ClipboardWriteMIME,
                    data: ""
                ),
            ],
            to: pasteboard
        )

        XCTAssertEqual(
            diagnostic,
            .pasteboardRejected(
                entryCount: 1,
                byteCount: copiedText.utf8.count
            )
        )
    }

    func testFocusDidChangeSkipsFocusSetterWhenPaneInputSinkIsSet() throws {
        let appHandle = try requireAppHandle()
        let previousSetter = TerminalSurfaceView.focusSetter
        var focusSetterCalls: [Bool] = []
        TerminalSurfaceView.focusSetter = { _, focused in
            focusSetterCalls.append(focused)
        }
        defer { TerminalSurfaceView.focusSetter = previousSetter }

        let view = makeSurface(
            app: appHandle,
            configuration: TerminalSurfaceConfiguration()
        )
        view.tmuxPaneInputSink = { _ in }
        _ = hostInWindow(view)

        view.focusDidChange(false)
        view.focusDidChange(true)

        XCTAssertTrue(
            focusSetterCalls.isEmpty,
            "focusSetter must never be invoked for a pane-routed surface, across mount and focus transitions."
        )
    }

    private func assertInteractiveControlChordMovement(
        configuration: TerminalSurfaceConfiguration,
        hostMode: HostMode,
        eventRoute: EventRoute = .window,
        textBeforeChord: String,
        chordCharacters: String,
        chordKey: String,
        chordKeyCode: UInt16,
        successText: String,
        commandNotFoundText: String,
        chordName: String,
        hostWindowBuilder: ((TerminalSurfaceView, CGSize) -> NSWindow)? = nil
    ) throws {
        let appHandle = try requireAppHandle()

        let view = makeSurface(
            app: appHandle,
            configuration: configuration
        )
        let window = if let hostWindowBuilder {
            hostWindowBuilder(view, CGSize(width: 800, height: 600))
        } else {
            hostWindow(
                for: view,
                mode: hostMode,
                size: CGSize(width: 800, height: 600)
            )
        }
        waitForViewportText("PROMPT> ", in: view, timeout: 10.0)

        typeText(textBeforeChord, into: view, window: window)
        dispatch(
            makeKeyEvent(
                characters: chordCharacters,
                charactersIgnoringModifiers: chordKey,
                modifiers: [.control],
                keyCode: chordKeyCode,
                windowNumber: window.windowNumber
            ),
            to: window,
            route: eventRoute
        )
        settleInputPipeline()
        typeText("X\r", into: view, window: window)

        waitUntil(timeout: 10.0) {
            self.interactiveChordTextMatches(
                in: view,
                successText: successText,
                commandNotFoundText: commandNotFoundText
            )
        }

        let contents = readViewportText(from: view)
        XCTAssertTrue(
            interactiveChordTextMatches(
                in: view,
                successText: successText,
                commandNotFoundText: commandNotFoundText
            ),
            "Expected \(chordName) to move cursor before inserting X in \(hostMode). Contents: \(contents)"
        )
    }

    private func assertInteractiveControlAMovesToBeginningOfLine(
        configuration: TerminalSurfaceConfiguration,
        hostMode: HostMode,
        eventRoute: EventRoute = .window,
        commandNotFoundText: String,
        hostWindowBuilder: ((TerminalSurfaceView, CGSize) -> NSWindow)? = nil
    ) throws {
        try assertInteractiveControlChordMovement(
            configuration: configuration,
            hostMode: hostMode,
            eventRoute: eventRoute,
            textBeforeChord: "echo abc",
            chordCharacters: "\u{1}",
            chordKey: "a",
            chordKeyCode: 0,
            successText: "PROMPT> Xecho abc",
            commandNotFoundText: commandNotFoundText,
            chordName: "Ctrl-A",
            hostWindowBuilder: hostWindowBuilder
        )
    }

    private func assertInteractiveControlEMovesToEndOfLine(
        configuration: TerminalSurfaceConfiguration,
        hostMode: HostMode,
        eventRoute: EventRoute = .window,
        commandNotFoundText: String,
        hostWindowBuilder: ((TerminalSurfaceView, CGSize) -> NSWindow)? = nil
    ) throws {
        try assertInteractiveControlChordMovement(
            configuration: configuration,
            hostMode: hostMode,
            eventRoute: eventRoute,
            textBeforeChord: "abc",
            chordCharacters: "\u{5}",
            chordKey: "e",
            chordKeyCode: 14,
            successText: "PROMPT> abcX",
            commandNotFoundText: commandNotFoundText,
            chordName: "Ctrl-E",
            hostWindowBuilder: hostWindowBuilder
        )
    }

}
