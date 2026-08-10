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

    @Test("only navigation actions accept key repeat")
    func repeatPolicyComesFromCatalog() throws {
        let navigation = try #require(keyEvent(
            modifiers: [.control], characters: "\t", keyCode: 48,
            isRepeat: true
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
        #expect(monitor.processForTesting(palette) === palette)
        #expect(actions == [.nextSibling])
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
        modifiers: NSEvent.ModifierFlags,
        characters: String,
        keyCode: UInt16,
        isRepeat: Bool = false
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
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
