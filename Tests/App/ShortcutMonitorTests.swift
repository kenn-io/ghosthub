#if canImport(AppKit)
import AppKit
import GhosthubTerminalSupport
import Testing
@testable import GhosthubApp

@MainActor
struct ShortcutMonitorTests {
    @Test("AppKit translation handles named keys without characters")
    func translatesNamedKeys() {
        #expect(binding([.control], nil, 48)?.key == .tab)
        #expect(binding([.command], nil, 123)?.key == .leftArrow)
        #expect(binding([.option], nil, 36)?.key == .return)
        #expect(binding([.control], nil, 53)?.key == .escape)
        #expect(binding([.command], nil, 51)?.key == .delete)
        #expect(binding([.command], nil, 122)?.key == .function(1))
    }

    @Test("matched events are consumed only after successful dispatch")
    func consumesOnlySuccessfulActions() throws {
        var handled = false
        let monitor = ShortcutMonitor(
            shortcuts: { ApplicationShortcutCatalog.compiledDefaults },
            perform: { action in
                handled = action == .nextSibling
                return handled
            }
        )
        let event = try #require(keyEvent(
            modifiers: [.control], characters: "\t", keyCode: 48
        ))

        #expect(monitor.processForTesting(event) == nil)
        #expect(handled)

        handled = false
        let unavailable = ShortcutMonitor(
            shortcuts: { ApplicationShortcutCatalog.compiledDefaults },
            perform: { _ in false }
        )
        #expect(unavailable.processForTesting(event) === event)
    }

    @Test("toggle sidebar stays owned by the menu key equivalent")
    func toggleSidebarPassesThroughToMenu() throws {
        var actions: [ApplicationShortcutAction] = []
        let monitor = ShortcutMonitor(
            shortcuts: { ApplicationShortcutCatalog.compiledDefaults },
            perform: { action in
                actions.append(action)
                return true
            }
        )
        let keyDown = try #require(keyEvent(
            modifiers: [.command], characters: "b", keyCode: 11
        ))
        let keyRepeat = try #require(keyEvent(
            modifiers: [.command], characters: "b", keyCode: 11,
            isRepeat: true
        ))
        let keyUp = try #require(keyEvent(
            type: .keyUp,
            modifiers: [.command], characters: "b", keyCode: 11
        ))

        #expect(monitor.processForTesting(keyDown) === keyDown)
        #expect(monitor.processForTesting(keyRepeat) == nil)
        #expect(monitor.processForTesting(keyUp) === keyUp)
        #expect(monitor.processForTesting(keyDown) === keyDown)
        #expect(actions.isEmpty)
    }

    @Test("the registry provider is read for every event")
    func readsLiveRegistry() throws {
        var resolved = ApplicationShortcutCatalog.compiledDefaults
        var actions: [ApplicationShortcutAction] = []
        let monitor = ShortcutMonitor(
            shortcuts: { resolved },
            perform: { actions.append($0)
                return true
            }
        )
        let event = try #require(keyEvent(
            modifiers: [.control], characters: "\t", keyCode: 48
        ))
        #expect(monitor.processForTesting(event) == nil)

        resolved = try ApplicationShortcutCatalog.resolve(overrides: [
            .nextSibling: .unbound,
        ])
        #expect(monitor.processForTesting(event) === event)
        #expect(actions == [.nextSibling])
    }

    @Test("handled non-repeating shortcuts consume repeats without dispatch")
    func handledNonRepeatingShortcutConsumesRepeat() throws {
        let navigation = try #require(keyEvent(
            modifiers: [.control], characters: "\t", keyCode: 48,
            isRepeat: true
        ))
        let paletteKeyDown = try #require(keyEvent(
            modifiers: [.command, .shift], characters: "p", keyCode: 35
        ))
        let palette = try #require(keyEvent(
            modifiers: [.command, .shift], characters: "p", keyCode: 35,
            isRepeat: true
        ))
        var actions: [ApplicationShortcutAction] = []
        let monitor = ShortcutMonitor(
            shortcuts: { ApplicationShortcutCatalog.compiledDefaults },
            perform: { actions.append($0)
                return true
            }
        )

        #expect(monitor.processForTesting(navigation) == nil)
        #expect(monitor.processForTesting(paletteKeyDown) == nil)
        #expect(monitor.processForTesting(palette) == nil)
        #expect(actions == [.nextSibling, .commandPalette])
    }

    @Test("unavailable non-repeating shortcuts pass through every key-down")
    func unavailableNonRepeatingShortcutPassesThrough() throws {
        let keyDown = try #require(keyEvent(
            modifiers: [.command, .shift], characters: "p", keyCode: 35
        ))
        let keyRepeat = try #require(keyEvent(
            modifiers: [.command, .shift], characters: "p", keyCode: 35,
            isRepeat: true
        ))
        var attempts = 0
        let monitor = ShortcutMonitor(
            shortcuts: { ApplicationShortcutCatalog.compiledDefaults },
            perform: { _ in
                attempts += 1
                return false
            }
        )

        #expect(monitor.processForTesting(keyDown) === keyDown)
        #expect(monitor.processForTesting(keyRepeat) === keyRepeat)
        #expect(attempts == 1)
    }

    @Test("consumed key-downs consume only their matching release")
    func consumedKeyDownConsumesMatchingRelease() throws {
        var actions: [ApplicationShortcutAction] = []
        let monitor = ShortcutMonitor(
            shortcuts: { ApplicationShortcutCatalog.compiledDefaults },
            perform: { actions.append($0)
                return true
            }
        )
        let keyDown = try #require(keyEvent(
            modifiers: [.control], characters: "\t", keyCode: 48
        ))
        let unrelatedKeyUp = try #require(keyEvent(
            type: .keyUp,
            modifiers: [.command, .shift], characters: "p", keyCode: 35
        ))
        let matchingKeyUp = try #require(keyEvent(
            type: .keyUp,
            modifiers: [], characters: "", keyCode: 48
        ))

        #expect(monitor.processForTesting(keyDown) == nil)
        #expect(monitor.processForTesting(unrelatedKeyUp) === unrelatedKeyUp)
        #expect(monitor.processForTesting(matchingKeyUp) == nil)
        #expect(monitor.processForTesting(matchingKeyUp) === matchingKeyUp)
        #expect(actions == [.nextSibling])
    }

    @Test("unavailable key-downs leave their release for the terminal")
    func unavailableKeyDownLeavesRelease() throws {
        let monitor = ShortcutMonitor(
            shortcuts: { ApplicationShortcutCatalog.compiledDefaults },
            perform: { _ in false }
        )
        let keyDown = try #require(keyEvent(
            modifiers: [.control], characters: "\t", keyCode: 48
        ))
        let keyUp = try #require(keyEvent(
            type: .keyUp,
            modifiers: [], characters: "", keyCode: 48
        ))

        #expect(monitor.processForTesting(keyDown) === keyDown)
        #expect(monitor.processForTesting(keyUp) === keyUp)
    }

    private func binding(
        _ modifiers: NSEvent.ModifierFlags,
        _ characters: String?,
        _ keyCode: UInt16
    ) -> ApplicationKeyBinding? {
        ApplicationKeyBinding(
            appKitModifierFlags: modifiers.union(.capsLock),
            charactersIgnoringModifiers: characters,
            keyCode: keyCode
        )
    }

    private func keyEvent(
        type: NSEvent.EventType = .keyDown,
        modifiers: NSEvent.ModifierFlags,
        characters: String,
        keyCode: UInt16,
        isRepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: isRepeat,
            keyCode: keyCode
        )
    }
}
#endif
