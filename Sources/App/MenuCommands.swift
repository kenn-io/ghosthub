import GhosthubSettings
import GhosthubTerminalSupport
import GhosthubWorkspace
import SwiftUI
#if canImport(AppKit)
import AppKit

// Menu commands read focused values inside dedicated `Commands` types so a
// key-window change invalidates only the menu graph. Reading focused values
// at the `App` level makes every window switch rebuild the whole scene:
// SwiftUI re-runs the `WindowGroup` content for every open window, which is
// the dominant cost of window activation.

/// Shared helpers for menu items that dispatch application shortcuts to the
/// focused scene.
@MainActor
struct MenuActionContext {
    let sceneModel: WorkspaceSceneModel?
    let terminalHasEffectiveKeyboardFocus: Bool?
    let settingsStore: SettingsStore

    func shortcut(
        _ action: ApplicationShortcutAction,
        actionIsAvailable: Bool = true
    ) -> KeyboardShortcut? {
        ApplicationShortcutMenuModel.keyboardBinding(
            settingsStore.shortcutPreferences.resolved[action],
            for: action,
            sceneIsFocused:
            sceneModel?.acceptsApplicationShortcutKeyEvents == true,
            hasAttachedSheet: sceneHasAttachedSheet,
            actionIsAvailable: actionIsAvailable
        )?.swiftUI
    }

    func splitShortcut(
        _ action: ApplicationShortcutAction
    ) -> KeyboardShortcut? {
        let splitBinding = ApplicationShortcutMenuModel.splitBinding(
            settingsStore.shortcutPreferences.resolved[action],
            terminalHasEffectiveKeyboardFocus:
            terminalHasEffectiveKeyboardFocus
        )
        return ApplicationShortcutMenuModel.keyboardBinding(
            splitBinding,
            for: action,
            sceneIsFocused:
            sceneModel?.acceptsApplicationShortcutKeyEvents == true,
            hasAttachedSheet: sceneHasAttachedSheet,
            actionIsAvailable: sceneModel?.canSplitActivePane == true
        )?.swiftUI
    }

    var sceneHasAttachedSheet: Bool {
        guard let sceneModel else { return false }
        return sceneModel.isSettingsPresented
            || sceneModel.isCommandPalettePresented
            || sceneModel.isLogViewerPresented
    }

    func invoke(_ action: ApplicationShortcutAction) {
        let invocation = ApplicationShortcutMenuModel.invocation(
            currentEvent: NSApplication.shared.currentEvent,
            binding: settingsStore.shortcutPreferences.resolved[action]
        )
        _ = sceneModel?.performApplicationShortcut(
            action,
            invocation: invocation
        )
    }
}

struct AppMenuCommands: Commands {
    let updateController: UpdateController
    @FocusedValue(\.sceneModel) private var focusedSceneModel
    @ObservedObject private var settingsStore = SettingsStore.shared

    private var context: MenuActionContext {
        MenuActionContext(
            sceneModel: focusedSceneModel,
            terminalHasEffectiveKeyboardFocus: nil,
            settingsStore: settingsStore
        )
    }

    var body: some Commands {
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
                context.invoke(.reloadConfiguration)
            }
            .keyboardShortcut(context.shortcut(.reloadConfiguration))
            Divider()
            Button("Application Log") {
                context.invoke(.openApplicationLog)
            }
            .keyboardShortcut(context.shortcut(.openApplicationLog))
        }
    }
}

struct FindMenuCommands: Commands {
    @FocusedValue(\.sceneModel) private var focusedSceneModel
    @FocusedObject private var findController: TerminalFindController?
    @ObservedObject private var settingsStore = SettingsStore.shared

    private var context: MenuActionContext {
        MenuActionContext(
            sceneModel: focusedSceneModel,
            terminalHasEffectiveKeyboardFocus: nil,
            settingsStore: settingsStore
        )
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            if let findController {
                Divider()
                Button("Find…") {
                    context.invoke(.find)
                }
                .keyboardShortcut(context.shortcut(
                    .find,
                    actionIsAvailable: findController.isAvailable
                ))
                .disabled(!findController.isAvailable)

                Button("Find Next") {
                    context.invoke(.findNext)
                }
                .keyboardShortcut(context.shortcut(
                    .findNext,
                    actionIsAvailable: findController.canNavigate
                ))
                .disabled(!findController.canNavigate)

                Button("Find Previous") {
                    context.invoke(.findPrevious)
                }
                .keyboardShortcut(context.shortcut(
                    .findPrevious,
                    actionIsAvailable: findController.canNavigate
                ))
                .disabled(!findController.canNavigate)

                Button("Hide Find Bar") {
                    context.invoke(.hideFindBar)
                }
                .keyboardShortcut(context.shortcut(
                    .hideFindBar,
                    actionIsAvailable: findController.isOpen
                ))
                .disabled(!findController.isOpen)
            }
        }
    }
}

struct FileMenuCommands: Commands {
    let applicationDelegate: ApplicationDelegate
    @FocusedValue(\.sceneModel) private var focusedSceneModel
    @FocusedValue(\.terminalHasEffectiveKeyboardFocus)
    private var terminalHasEffectiveKeyboardFocus
    @ObservedObject private var settingsStore = SettingsStore.shared

    private var context: MenuActionContext {
        MenuActionContext(
            sceneModel: focusedSceneModel,
            terminalHasEffectiveKeyboardFocus:
            terminalHasEffectiveKeyboardFocus,
            settingsStore: settingsStore
        )
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Worktree…") {
                context.invoke(.newWorktree)
            }
            .keyboardShortcut(context.shortcut(
                .newWorktree,
                actionIsAvailable:
                focusedSceneModel?.canCreateWorktreeInSelectedProject == true
            ))
            .disabled(
                focusedSceneModel?.canCreateWorktreeInSelectedProject
                    != true
            )

            Button("Import Pull Request…") {
                context.invoke(.importPullRequest)
            }
            .keyboardShortcut(context.shortcut(
                .importPullRequest,
                actionIsAvailable:
                focusedSceneModel?.canImportPullRequestInSelectedProject
                    == true
            ))
            .disabled(
                focusedSceneModel?.canImportPullRequestInSelectedProject
                    != true
            )

            Divider()

            Button("New Window") {
                applicationDelegate.requestNewWorkspaceWindow()
            }
            .keyboardShortcut("n")

            Button("New Tab") {
                applicationDelegate.requestNewWorkspaceTab()
            }
            .keyboardShortcut("t")

            Divider()

            Button("Split Right") {
                context.invoke(.splitRight)
            }
            .keyboardShortcut(context.splitShortcut(.splitRight))
            .disabled(focusedSceneModel?.canSplitActivePane != true)

            Button("Split Down") {
                context.invoke(.splitDown)
            }
            .keyboardShortcut(context.splitShortcut(.splitDown))
            .disabled(focusedSceneModel?.canSplitActivePane != true)

            Divider()

            Button("Close") {
                if let focusedSceneModel {
                    NotificationCenter.default.post(
                        name: .ghosthubCloseTab,
                        object: focusedSceneModel
                    )
                } else {
                    applicationDelegate.requestWorkspaceTabClose(
                        NSApplication.shared.keyWindow
                    )
                }
            }
            .keyboardShortcut("w")

            Button("Close Window") {
                applicationDelegate.requestWorkspaceWindowClose(
                    NSApplication.shared.keyWindow
                )
            }
            .keyboardShortcut(
                "w",
                modifiers: [.command, .shift]
            )
        }
    }
}

struct SessionMenuCommands: Commands {
    @FocusedValue(\.sceneModel) private var focusedSceneModel
    @FocusedValue(\.availableSiblingShortcuts)
    private var availableSiblingShortcuts
    @ObservedObject private var settingsStore = SettingsStore.shared

    private var context: MenuActionContext {
        MenuActionContext(
            sceneModel: focusedSceneModel,
            terminalHasEffectiveKeyboardFocus: nil,
            settingsStore: settingsStore
        )
    }

    var body: some Commands {
        CommandMenu("Session") {
            Button("Previous Sibling") {
                context.invoke(.previousSibling)
            }
            .keyboardShortcut(context.shortcut(
                .previousSibling,
                actionIsAvailable: availableSiblingShortcuts?
                    .contains(.previousSibling) == true
            ))
            .disabled(
                availableSiblingShortcuts?.contains(.previousSibling) != true
            )

            Button("Next Sibling") {
                context.invoke(.nextSibling)
            }
            .keyboardShortcut(context.shortcut(
                .nextSibling,
                actionIsAvailable: availableSiblingShortcuts?
                    .contains(.nextSibling) == true
            ))
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
                        context.invoke(definition.action)
                    }
                    .keyboardShortcut(context.shortcut(
                        definition.action,
                        actionIsAvailable: availableSiblingShortcuts?
                            .contains(definition.action) == true
                    ))
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
}

struct ViewMenuCommands: Commands {
    @FocusedValue(\.sceneModel) private var focusedSceneModel
    @ObservedObject private var settingsStore = SettingsStore.shared

    private var context: MenuActionContext {
        MenuActionContext(
            sceneModel: focusedSceneModel,
            terminalHasEffectiveKeyboardFocus: nil,
            settingsStore: settingsStore
        )
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Command Palette") {
                context.invoke(.commandPalette)
            }
            .keyboardShortcut(context.shortcut(.commandPalette))
            .disabled(focusedSceneModel == nil)

            Divider()

            Button("Toggle Sidebar") {
                context.invoke(.toggleSidebar)
            }
            .keyboardShortcut(context.shortcut(.toggleSidebar))
            .disabled(focusedSceneModel == nil)
        }
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
#endif
