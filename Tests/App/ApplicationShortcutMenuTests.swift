import AppKit
import GhosthubTerminalSupport
import SwiftUI
import Testing
@testable import GhosthubApp

struct ApplicationShortcutMenuTests {
    @Test("menu projections use the resolved registry")
    func menuProjection() throws {
        let shortcuts = try ApplicationShortcutCatalog.resolve(overrides: [
            .nextSibling: .binding(
                try ApplicationKeyBinding(parsing: "cmd+k")
            ),
            .splitRight: .unbound,
        ])

        let items = ApplicationShortcutMenuModel.items(
            [.previousSibling, .nextSibling, .splitRight],
            shortcuts: shortcuts
        )

        #expect(items[0].binding?.configValue == "ctrl+shift+tab")
        #expect(items[1].binding?.configValue == "cmd+k")
        #expect(items[2].binding == nil)
    }

    @Test("Return-driven menu activation stays a menu invocation")
    func returnMenuActivation() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        let binding = try ApplicationKeyBinding(parsing: "cmd+d")

        #expect(ApplicationShortcutMenuModel.invocation(
            currentEvent: event,
            binding: binding
        ) == .menu)
    }

    @Test("matching menu shortcut stays a key event invocation")
    func matchingShortcutActivation() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "d",
            charactersIgnoringModifiers: "d",
            isARepeat: false,
            keyCode: 2
        ))
        let binding = try ApplicationKeyBinding(parsing: "cmd+d")

        #expect(ApplicationShortcutMenuModel.invocation(
            currentEvent: event,
            binding: binding
        ) == .keyEvent)
    }

    @Test("plus projects to the physical SwiftUI chord")
    func plusMenuProjection() throws {
        let shortcut = try ApplicationKeyBinding(
            parsing: "cmd+plus"
        ).swiftUI

        #expect(shortcut.key == KeyEquivalent("="))
        #expect(shortcut.modifiers == [.command, .shift])
    }

    @Test("split key equivalents require effective terminal focus")
    func splitKeyEquivalentRequiresTerminalFocus() throws {
        let binding = try ApplicationKeyBinding(parsing: "cmd+d")

        #expect(ApplicationShortcutMenuModel.splitBinding(
            binding,
            terminalHasEffectiveKeyboardFocus: nil
        ) == nil)
        #expect(ApplicationShortcutMenuModel.splitBinding(
            binding,
            terminalHasEffectiveKeyboardFocus: false
        ) == nil)
        #expect(ApplicationShortcutMenuModel.splitBinding(
            binding,
            terminalHasEffectiveKeyboardFocus: true
        ) == binding)
    }

    @Test("menu bindings require an available sheet-free focused scene")
    func bindingRequiresKeyboardAvailability() throws {
        let binding = try ApplicationKeyBinding(parsing: "ctrl+k")

        #expect(ApplicationShortcutMenuModel.keyboardBinding(
            binding,
            for: .newWorktree,
            sceneIsFocused: true,
            hasAttachedSheet: false,
            actionIsAvailable: true
        ) == binding)
        #expect(ApplicationShortcutMenuModel.keyboardBinding(
            binding,
            for: .newWorktree,
            sceneIsFocused: false,
            hasAttachedSheet: false,
            actionIsAvailable: true
        ) == nil)
        #expect(ApplicationShortcutMenuModel.keyboardBinding(
            binding,
            for: .newWorktree,
            sceneIsFocused: true,
            hasAttachedSheet: true,
            actionIsAvailable: true
        ) == nil)
        #expect(ApplicationShortcutMenuModel.keyboardBinding(
            binding,
            for: .newWorktree,
            sceneIsFocused: true,
            hasAttachedSheet: false,
            actionIsAvailable: false
        ) == nil)
    }

    @Test("the Application Log sheet keeps only the Find bindings")
    func logViewerSheetKeepsFindBindings() {
        #expect(!ApplicationShortcutMenuModel.sheetSuppressesBinding(
            for: .find,
            settingsPresented: false,
            commandPalettePresented: false,
            logViewerPresented: true
        ))
        #expect(ApplicationShortcutMenuModel.sheetSuppressesBinding(
            for: .newWorktree,
            settingsPresented: false,
            commandPalettePresented: false,
            logViewerPresented: true
        ))
        #expect(ApplicationShortcutMenuModel.sheetSuppressesBinding(
            for: .find,
            settingsPresented: true,
            commandPalettePresented: false,
            logViewerPresented: false
        ))
    }

    @Test("menu-owned bindings remain registered across live eligibility changes")
    func menuOwnedBindingsRemainRegistered() throws {
        let binding = try ApplicationKeyBinding(parsing: "cmd+b")

        #expect(ApplicationShortcutMenuModel.keyboardBinding(
            binding,
            for: .toggleSidebar,
            sceneIsFocused: false,
            hasAttachedSheet: true,
            actionIsAvailable: false
        ) == binding)
        #expect(ApplicationShortcutMenuModel.keyboardBinding(
            nil,
            for: .toggleSidebar,
            sceneIsFocused: true,
            hasAttachedSheet: false,
            actionIsAvailable: true
        ) == nil)
    }
}
