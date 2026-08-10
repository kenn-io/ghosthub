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
    @FocusedValue(\.availableSiblingShortcuts)
    private var availableSiblingShortcuts
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
                    invoke(.reloadConfiguration)
                }
                .keyboardShortcut(shortcut(.reloadConfiguration))
                Divider()
                Button("Application Log") {
                    invoke(.openApplicationLog)
                }
                .keyboardShortcut(shortcut(.openApplicationLog))
            }
            CommandGroup(replacing: .toolbar) {}
            editMenuCommands
            fileMenuCommands
            sessionMenuCommands
            viewMenuCommands
            CommandGroup(after: .windowArrangement) {
                Button("Previous Tab") {
                    NativeTabCommands.selectPrevious()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Next Tab") {
                    NativeTabCommands.selectNext()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
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

    // MARK: - File menu

    @CommandsBuilder
    private var fileMenuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Worktree…") {
                invoke(.newWorktree)
            }
            .keyboardShortcut(shortcut(.newWorktree))
            .disabled(focusedSceneModel?.selectedProject == nil)

            Button("Import Pull Request…") {
                invoke(.importPullRequest)
            }
            .keyboardShortcut(shortcut(.importPullRequest))
            .disabled(
                focusedSceneModel?.canImportPullRequestInSelectedProject
                    != true
            )

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

            Button("Split Right") {
                invoke(.splitRight)
            }
            .keyboardShortcut(shortcut(.splitRight))
            .disabled(focusedSceneModel?.canSplitActivePane != true)

            Button("Split Down") {
                invoke(.splitDown)
            }
            .keyboardShortcut(shortcut(.splitDown))
            .disabled(focusedSceneModel?.canSplitActivePane != true)

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
            Button("Previous Sibling") {
                invoke(.previousSibling)
            }
            .keyboardShortcut(shortcut(.previousSibling))
            .disabled(
                availableSiblingShortcuts?.contains(.previousSibling) != true
            )

            Button("Next Sibling") {
                invoke(.nextSibling)
            }
            .keyboardShortcut(shortcut(.nextSibling))
            .disabled(
                availableSiblingShortcuts?.contains(.nextSibling) != true
            )

            Menu("Select Sibling") {
                ForEach(
                    ApplicationShortcutCatalog.definitions.filter {
                        $0.action.siblingIndex != nil
                    },
                    id: \.action
                ) { definition in
                    Button(definition.title) {
                        invoke(definition.action)
                    }
                    .keyboardShortcut(shortcut(definition.action))
                    .disabled(
                        availableSiblingShortcuts?.contains(
                            definition.action
                        ) != true
                    )
                }
            }

            Divider()

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
                invoke(.commandPalette)
            }
            .keyboardShortcut(shortcut(.commandPalette))

            Divider()

            Button("Toggle Sidebar") {
                invoke(.toggleSidebar)
            }
            .keyboardShortcut(shortcut(.toggleSidebar))
            .disabled(focusedSceneModel == nil)
        }
    }

    private func shortcut(
        _ action: ApplicationShortcutAction
    ) -> KeyboardShortcut? {
        settingsStore.shortcutPreferences.resolved[action]?.swiftUI
    }

    private func invoke(_ action: ApplicationShortcutAction) {
        let invocation = ApplicationShortcutMenuModel.invocation(
            currentEvent: NSApplication.shared.currentEvent,
            binding: settingsStore.shortcutPreferences.resolved[action]
        )
        _ = focusedSceneModel?.performApplicationShortcut(
            action,
            invocation: invocation
        )
    }
}

extension ApplicationKeyBinding {
    var swiftUI: KeyboardShortcut {
        KeyboardShortcut(swiftUIKey, modifiers: swiftUIModifiers)
    }

    var swiftUIKey: KeyEquivalent {
        switch key {
        case .character("+"): KeyEquivalent("=")
        case let .character(character): KeyEquivalent(character)
        case .tab: .tab
        case .return: .return
        case .escape: .escape
        case .delete: .delete
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case let .function(number):
            KeyEquivalent(Character(UnicodeScalar(0xF703 + number)!))
        }
    }

    var swiftUIModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) {
            result.insert(.command)
        }
        if modifiers.contains(.control) {
            result.insert(.control)
        }
        if modifiers.contains(.option) {
            result.insert(.option)
        }
        if modifiers.contains(.shift) {
            result.insert(.shift)
        }
        if key == .character("+") {
            result.insert(.shift)
        }
        return result
    }
}
