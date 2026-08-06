import GhosttyKit
import UIKit

struct IOSMappedKey: Equatable {
    let keycode: UInt32
    let modifiers: ghostty_input_mods_e
    let text: String?
    let unshiftedCodepoint: UInt32
}

enum IOSKeyboardRoute: Equatable {
    case deferToTextInput
    case text(String)
    case key(IOSMappedKey)
}

enum IOSKeyboardMapper {
    static func virtualKeycode(for usage: UIKeyboardHIDUsage) -> UInt32? {
        let letterKeycodes: [UInt32] = [
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05,
            0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, 0x2D,
            0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20,
            0x09, 0x0D, 0x07, 0x10, 0x06,
        ]
        let letterOffset = usage.rawValue - UIKeyboardHIDUsage.keyboardA.rawValue
        if letterKeycodes.indices.contains(letterOffset) {
            return letterKeycodes[letterOffset]
        }

        return switch usage {
        case .keyboardReturnOrEnter: 0x24
        case .keyboardEscape: 0x35
        case .keyboardDeleteOrBackspace: 0x33
        case .keyboardTab: 0x30
        case .keyboardSpacebar: 0x31
        case .keyboardLeftArrow: 0x7B
        case .keyboardRightArrow: 0x7C
        case .keyboardDownArrow: 0x7D
        case .keyboardUpArrow: 0x7E
        case .keyboardF1: 0x7A
        case .keyboardF2: 0x78
        case .keyboardF3: 0x63
        case .keyboardF4: 0x76
        case .keyboardF5: 0x60
        case .keyboardF6: 0x61
        case .keyboardF7: 0x62
        case .keyboardF8: 0x64
        case .keyboardF9: 0x65
        case .keyboardF10: 0x6D
        case .keyboardF11: 0x67
        case .keyboardF12: 0x6F
        case .keyboardInsert: 0x72
        case .keyboardHome: 0x73
        case .keyboardPageUp: 0x74
        case .keyboardDeleteForward: 0x75
        case .keyboardEnd: 0x77
        case .keyboardPageDown: 0x79
        case .keypadEnter: 0x4C
        default: nil
        }
    }

    static func modifiers(for flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
        var rawValue = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) {
            rawValue |= GHOSTTY_MODS_SHIFT.rawValue
        }
        if flags.contains(.control) {
            rawValue |= GHOSTTY_MODS_CTRL.rawValue
        }
        if flags.contains(.alternate) {
            rawValue |= GHOSTTY_MODS_ALT.rawValue
        }
        if flags.contains(.command) {
            rawValue |= GHOSTTY_MODS_SUPER.rawValue
        }
        if flags.contains(.alphaShift) {
            rawValue |= GHOSTTY_MODS_CAPS.rawValue
        }
        return ghostty_input_mods_e(rawValue)
    }

    static func pressRoute(
        usage: UIKeyboardHIDUsage,
        characters: String,
        charactersIgnoringModifiers: String,
        modifiers flags: UIKeyModifierFlags
    ) -> IOSKeyboardRoute? {
        guard let keycode = virtualKeycode(for: usage) else { return nil }
        let isSpecial = specialUsages.contains(usage)
        if flags.isEmpty, !isSpecial {
            return .deferToTextInput
        }

        let text: String? = if isSpecial {
            nil
        } else if characters.unicodeScalars.first?.value ?? 0 < 0x20 {
            charactersIgnoringModifiers
        } else {
            characters
        }
        return .key(
            IOSMappedKey(
                keycode: keycode,
                modifiers: modifiers(for: flags),
                text: text?.isEmpty == true ? nil : text,
                unshiftedCodepoint: singleCodepoint(in: charactersIgnoringModifiers)
            )
        )
    }

    static func textInputRoute(_ text: String) -> IOSKeyboardRoute? {
        text.isEmpty ? nil : .text(text)
    }

    static func deleteRoute() -> IOSKeyboardRoute {
        .key(
            IOSMappedKey(
                keycode: 0x33,
                modifiers: GHOSTTY_MODS_NONE,
                text: nil,
                unshiftedCodepoint: 0x08
            )
        )
    }

    private static let specialUsages: Set<UIKeyboardHIDUsage> = [
        .keyboardReturnOrEnter,
        .keyboardEscape,
        .keyboardDeleteOrBackspace,
        .keyboardTab,
        .keyboardLeftArrow,
        .keyboardRightArrow,
        .keyboardDownArrow,
        .keyboardUpArrow,
        .keyboardF1,
        .keyboardF2,
        .keyboardF3,
        .keyboardF4,
        .keyboardF5,
        .keyboardF6,
        .keyboardF7,
        .keyboardF8,
        .keyboardF9,
        .keyboardF10,
        .keyboardF11,
        .keyboardF12,
        .keyboardInsert,
        .keyboardHome,
        .keyboardPageUp,
        .keyboardDeleteForward,
        .keyboardEnd,
        .keyboardPageDown,
        .keypadEnter,
    ]

    private static func singleCodepoint(in text: String) -> UInt32 {
        let scalars = text.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else { return 0 }
        return scalar.value
    }
}

struct IOSPressTracker {
    private var active: Set<ObjectIdentifier> = []

    mutating func begin(_ press: AnyObject) -> ghostty_input_action_e {
        active.insert(ObjectIdentifier(press)).inserted
            ? GHOSTTY_ACTION_PRESS
            : GHOSTTY_ACTION_REPEAT
    }

    mutating func end(_ press: AnyObject) -> Bool {
        active.remove(ObjectIdentifier(press)) != nil
    }

    mutating func removeAll() {
        active.removeAll()
    }
}
