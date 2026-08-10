#if canImport(AppKit)
import AppKit

public extension ApplicationShortcutModifiers {
    init(appKit flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Self = []
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        self = modifiers
    }

    var appKit: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) {
            flags.insert(.command)
        }
        if contains(.control) {
            flags.insert(.control)
        }
        if contains(.option) {
            flags.insert(.option)
        }
        if contains(.shift) {
            flags.insert(.shift)
        }
        return flags
    }
}

public extension ApplicationKeyBinding {
    init?(
        appKitModifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?,
        keyCode: UInt16
    ) {
        let key: ApplicationShortcutKey
        switch keyCode {
        case 48: key = .tab
        case 36: key = .return
        case 53: key = .escape
        case 51: key = .delete
        case 123: key = .leftArrow
        case 124: key = .rightArrow
        case 125: key = .downArrow
        case 126: key = .upArrow
        case 122: key = .function(1)
        case 120: key = .function(2)
        case 99: key = .function(3)
        case 118: key = .function(4)
        case 96: key = .function(5)
        case 97: key = .function(6)
        case 98: key = .function(7)
        case 100: key = .function(8)
        case 101: key = .function(9)
        case 109: key = .function(10)
        case 103: key = .function(11)
        case 111: key = .function(12)
        default:
            let charactersWithoutModifiers = charactersIgnoringModifiers
                .flatMap { characters in
                    NSEvent.keyEvent(
                        with: .keyDown,
                        location: .zero,
                        modifierFlags: appKitModifierFlags,
                        timestamp: 0,
                        windowNumber: 0,
                        context: nil,
                        characters: characters,
                        charactersIgnoringModifiers: characters,
                        isARepeat: false,
                        keyCode: keyCode
                    )?.characters(byApplyingModifiers: [])
                }
            guard let character = (charactersWithoutModifiers
                ?? charactersIgnoringModifiers)?
                .lowercased().first else { return nil }
            key = .character(character)
        }
        self.init(
            modifiers: .init(appKit: appKitModifierFlags),
            key: key
        )
    }
}
#endif
