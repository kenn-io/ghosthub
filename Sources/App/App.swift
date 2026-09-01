import SwiftUI
import GhosthubSettings
import GhosthubTerminal
import GhosthubTerminalSupport
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

struct ApplicationShortcutMenuItem: Equatable {
    let action: ApplicationShortcutAction
    let title: String
    let binding: ApplicationKeyBinding?
}

enum ApplicationShortcutMenuModel {
    static let menuOwnedActions: Set<ApplicationShortcutAction> = [
        .commandPalette,
        .toggleSidebar,
    ]

    static func items(
        _ actions: [ApplicationShortcutAction],
        shortcuts: ResolvedApplicationShortcuts
    ) -> [ApplicationShortcutMenuItem] {
        actions.map { action in
            ApplicationShortcutMenuItem(
                action: action,
                title: action.definition.title,
                binding: shortcuts[action]
            )
        }
    }

    static func invocation(
        currentEvent: NSEvent?,
        binding: ApplicationKeyBinding?
    ) -> ApplicationShortcutInvocation {
        guard let currentEvent,
              currentEvent.type == .keyDown,
              let binding,
              ApplicationKeyBinding(
                  appKitModifierFlags: currentEvent.modifierFlags,
                  charactersIgnoringModifiers:
                  currentEvent.charactersIgnoringModifiers,
                  keyCode: currentEvent.keyCode
              ) == binding
        else { return .menu }
        return .keyEvent
    }

    static func splitBinding(
        _ binding: ApplicationKeyBinding?,
        terminalHasEffectiveKeyboardFocus: Bool?
    ) -> ApplicationKeyBinding? {
        guard terminalHasEffectiveKeyboardFocus == true else { return nil }
        return binding
    }

    static func keyboardBinding(
        _ binding: ApplicationKeyBinding?,
        for action: ApplicationShortcutAction,
        sceneIsFocused: Bool,
        hasAttachedSheet: Bool,
        actionIsAvailable: Bool
    ) -> ApplicationKeyBinding? {
        if menuOwnedActions.contains(action) {
            return binding
        }
        guard sceneIsFocused,
              !hasAttachedSheet,
              actionIsAvailable
        else { return nil }
        return binding
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
    @Environment(\.openWindow) private var openWindow
    @State private var didRequestLaunchActivation = false
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self)
    private var appDelegate
    #endif

    init() {
        LibghosttyBootstrap.preconditionReady()
        AppLogger.shared.info("Ghosthub launched")
        if let issue = SettingsStore.shared.shortcutConfigurationIssue {
            AppLogger.shared.error(
                "shortcut configuration: \(issue.message)"
            )
        }
        WorkspaceSceneBootstrap.ensureBootstrapped()
        WorkspaceInventoryStore.shared.startApplicationActivityMonitoring()
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
                appDelegate.setWindowRestorationFinishedHandler { count in
                    updateRelaunchRestorer
                        .nativeWindowRestorationDidFinish(
                            expectedSceneCount: count
                        )
                }
                appDelegate.needsConfirmQuit = {
                    QuitPolicy.needsConfirmation(
                        confirmBeforeQuitting:
                        settingsStore.confirmBeforeQuitting
                    )
                }
                appDelegate.bindQuitRequests(from: terminalRuntime)
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
                NativeTabCommands.installBracketShortcuts()
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
            AppMenuCommands(updateController: updateController)
            CommandGroup(replacing: .toolbar) {}
            editMenuCommands
            FileMenuCommands(applicationDelegate: appDelegate)
            SessionMenuCommands()
            ViewMenuCommands()
            CommandGroup(after: .windowArrangement) {
                Button("Rename Window…") {
                    NotificationCenter.default.post(
                        name: .ghosthubRenameWorkspaceWindow,
                        object: NSApplication.shared.keyWindow
                    )
                }

                Divider()

                Button("Previous Tab") {
                    NativeTabCommands.selectPrevious()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Next Tab") {
                    NativeTabCommands.selectNext()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Divider()

                ForEach(1 ... 8, id: \.self) { shortcut in
                    Button("Select Tab \(shortcut)") {
                        NativeTabCommands.select(shortcut)
                    }
                    .keyboardShortcut(NativeTabCommands.binding(
                        for: shortcut,
                        claimedBy: settingsStore.shortcutPreferences.resolved
                    )?.swiftUI)
                }

                Button("Select Last Tab") {
                    NativeTabCommands.select(9)
                }
                .keyboardShortcut(NativeTabCommands.binding(
                    for: 9,
                    claimedBy: settingsStore.shortcutPreferences.resolved
                )?.swiftUI)
            }
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

}
