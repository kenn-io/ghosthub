import SwiftUI
import GhosthubSettings
import GhosthubTerminal
import GhosthubUI
import GhosthubWorkspace
#if canImport(AppKit)
import AppKit
#endif

enum QuitPolicy {
    static func needsConfirmation(
        confirmBeforeQuitting: Bool
    ) -> Bool {
        confirmBeforeQuitting
    }
}

@main
struct GhosthubApp: App {
    @StateObject private var terminalRuntime = LibghosttyRuntime.shared
    @StateObject private var settingsStore = SettingsStore.shared
    #if canImport(AppKit)
    private let updateController = UpdateController()
    private let updateRelaunchStore = UpdateRelaunchManifestStore()
    private let updateRelaunchRestorer = UpdateRelaunchRestorer()
    #endif
    @FocusedValue(\.sceneModel) private var focusedSceneModel
    @Environment(\.openWindow) private var openWindow
    @State private var didRequestLaunchActivation = false
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self)
    private var appDelegate
    #endif

    init() {
        LibghosttyBootstrap.preconditionReady()
        AppLogger.shared.info("Ghosthub launched")
        WorkspaceSceneBootstrap.ensureBootstrapped()
    }

    var body: some Scene {
        WindowGroup(
            "Ghosthub",
            id: "workspace",
            for: WorkspaceWindowState.self
        ) { windowState in
            WorkspaceWindow(
                applicationDelegate: appDelegate,
                windowState: windowState,
                updateRelaunchRestorer: updateRelaunchRestorer,
                openRelaunchWindow: { state in
                    openWindow(id: "workspace", value: state)
                }
            )
            .environmentObject(terminalRuntime)
            .onAppear {
                #if canImport(AppKit)
                AppAppearance.apply(
                    settingsStore.interfaceAppearance
                )
                appDelegate.openWorkspaceWindow = { windowState in
                    openWindow(
                        id: "workspace",
                        value: windowState
                    )
                }
                appDelegate.needsConfirmQuit = {
                    QuitPolicy.needsConfirmation(
                        confirmBeforeQuitting:
                        settingsStore.confirmBeforeQuitting
                    )
                }
                updateController.configureRelaunch(
                    prepareRelaunch: {
                        let states = WindowRegistry.shared
                            .captureRestorationStates()
                        do {
                            try updateRelaunchStore.save(states)
                        } catch {
                            AppLogger.shared.error(
                                "update relaunch: could not save windows: \(error)"
                            )
                        }
                    },
                    cancelRelaunch: {
                        do {
                            try updateRelaunchStore.clear()
                        } catch {
                            AppLogger.shared.error(
                                "update relaunch: could not discard saved windows: \(error)"
                            )
                        }
                    },
                    authorizeTermination: {
                        appDelegate.authorizeNextUpdaterTermination()
                    },
                    clearTerminationAuthorization: {
                        appDelegate.clearUpdaterTerminationAuthorization()
                    }
                )
                updateController.start()
                requestLaunchActivationIfNeeded()
                #endif
            }
            .onChange(
                of: settingsStore.interfaceAppearance
            ) { _, appearance in
                #if canImport(AppKit)
                AppAppearance.apply(appearance)
                #endif
            }
        }
        .defaultSize(width: 1600, height: 1000)
        .windowStyle(.hiddenTitleBar)
        .commands {
            #if canImport(AppKit)
            CommandGroup(replacing: .appInfo) {
                Button("About Ghosthub") {
                    let options = ApplicationVersion.aboutPanelVersion().map {
                        [NSApplication.AboutPanelOptionKey.version: $0]
                    } ?? [:]
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: options
                    )
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button("Quit Ghosthub") {
                    appDelegate.requestApplicationTermination()
                }
                .keyboardShortcut("q")
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.isAvailable)
                Divider()
                Button("Settings...") {
                    focusedSceneModel?
                        .isSettingsPresented = true
                }
                .keyboardShortcut(",")
                Button("Reload Configuration") {
                    focusedSceneModel?.reloadTerminalConfig()
                }
                .keyboardShortcut(
                    ",",
                    modifiers: [.command, .shift]
                )
                Divider()
                Button("Application Log") {
                    focusedSceneModel?
                        .isLogViewerPresented = true
                }
                .keyboardShortcut(
                    "l",
                    modifiers: [.command, .option]
                )
            }
            CommandGroup(replacing: .toolbar) {}
            editMenuCommands
            fileMenuCommands
            sessionMenuCommands
            viewMenuCommands
            #endif
        }
    }

    #if canImport(AppKit)
    @MainActor
    private func requestLaunchActivationIfNeeded() {
        guard !didRequestLaunchActivation else { return }
        didRequestLaunchActivation = true
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.unhide(nil)

        if let window = NSApplication.shared.windows.first {
            window.title = "Ghosthub"
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
        NSRunningApplication.current.activate(
            options: [.activateAllWindows]
        )

        for delay in [0.15, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay
            ) {
                guard !NSApplication.shared.isActive
                    || NSApplication.shared.keyWindow == nil
                else { return }

                if let window =
                    NSApplication.shared.windows.first {
                    window.title = "Ghosthub"
                    window.makeKeyAndOrderFront(nil)
                }
                NSRunningApplication.current.activate(
                    options: [.activateAllWindows]
                )
            }
        }
    }
    #endif

    // MARK: - Edit menu

    @CommandsBuilder
    private var editMenuCommands: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") {
                NSApp.sendAction(
                    #selector(NSText.cut(_:)),
                    to: nil, from: nil
                )
            }
            .keyboardShortcut("x")

            Button("Copy") {
                NSApp.sendAction(
                    #selector(NSText.copy(_:)),
                    to: nil, from: nil
                )
            }
            .keyboardShortcut("c")

            Button("Paste") {
                NSApp.sendAction(
                    #selector(NSText.paste(_:)),
                    to: nil, from: nil
                )
            }
            .keyboardShortcut("v")

            Button("Select All") {
                NSApp.sendAction(
                    #selector(NSText.selectAll(_:)),
                    to: nil, from: nil
                )
            }
            .keyboardShortcut("a")
        }
    }

    // MARK: - File menu

    @CommandsBuilder
    private var fileMenuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Worktree…") {
                NotificationCenter.default.post(
                    name: .ghosthubNewWorktree,
                    object: nil
                )
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(focusedSceneModel?.selectedProject == nil)

            Divider()

            Button("New Window") {
                appDelegate.requestNewWorkspaceWindow()
            }
            .keyboardShortcut("n")

            Button("New Tab") {
                appDelegate.requestNewWorkspaceTab()
            }
            .keyboardShortcut("t")

            Divider()

            Button("Close") {
                NotificationCenter.default.post(
                    name: .ghosthubCloseTab,
                    object: nil
                )
            }
            .keyboardShortcut("w")

            Button("Close Window") {
                appDelegate.requestWorkspaceWindowClose(
                    NSApplication.shared.keyWindow
                )
            }
            .keyboardShortcut(
                "w",
                modifiers: [.command, .shift]
            )
        }
    }

    // MARK: - Session menu

    @CommandsBuilder
    private var sessionMenuCommands: some Commands {
        CommandMenu("Session") {
            Button("Apply Theme to Current Session") {
                NotificationCenter.default.post(
                    name: .ghosthubApplyThemeToCurrentSession,
                    object: nil
                )
            }
            .disabled(
                focusedSceneModel?
                    .canApplyThemeToActiveTmuxSession != true
            )
        }
    }

    // MARK: - View menu

    @CommandsBuilder
    private var viewMenuCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Command Palette") {
                NotificationCenter.default.post(
                    name: .ghosthubCommandPalette,
                    object: nil
                )
            }
            .keyboardShortcut(
                "p",
                modifiers: [.command, .shift]
            )

            Divider()

            Button("Toggle Sidebar") {
                guard let focusedSceneModel else { return }
                NotificationCenter.default.post(
                    name: .ghosthubToggleSidebar,
                    object: focusedSceneModel
                )
            }
            .keyboardShortcut("b")
            .disabled(focusedSceneModel == nil)
        }
    }
}
