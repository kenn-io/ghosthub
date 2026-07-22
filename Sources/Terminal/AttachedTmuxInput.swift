// Adapted from fantastty (https://github.com/blaine/fantastty),
// commit 60d248d0. Copyright (c) 2026 Blaine Cook — MIT License
// (LICENSES/fantastty-MIT.txt).
//
// Ported from Fantastty/GhosttyBridge/SurfaceView_AppKit.swift (top of
// file, lines 8-296): `AttachedTmuxInputEncoder` and
// `AttachedTmuxInputRouter`. GhosthubTerminal keeps tmux types out of this
// module, so callers reach these types through the surface view's
// `tmuxPaneInputSink` closure rather than fantastty's `tmuxPaneID` /
// `tmuxControlClient` surface properties.

import AppKit
import GhosthubTerminalSupport
import GhosttyKit

typealias AttachedTmuxTerminalModeTracker = TmuxTerminalModeTracker

enum AttachedTmuxInputEncoder {

    // MARK: - Unicode scalars for macOS function key characters

    /// macOS function-key Unicode scalars that map to special escape sequences.
    /// These appear in `NSEvent.characters` for arrow keys, Home/End, etc.
    private static let functionKeyScalars: Set<UInt32> = [
        0xF700, // Up
        0xF701, // Down
        0xF702, // Left
        0xF703, // Right
        0xF727, // Insert
        0xF728, // Delete (forward)
        0xF729, // Home
        0xF72B, // End
        0xF72C, // PageUp
        0xF72D, // PageDown
    ]

    static func eventCharacters(for event: NSEvent) -> String? {
        switch event.type {
        case .keyDown, .keyUp:
            return event.characters
        default:
            return nil
        }
    }

    // MARK: - Primary encoding: raw bytes for printable text and control chars

    static func inputData(
        isRelease: Bool,
        text: String?,
        eventCharacters: String?,
        keyCode: UInt16? = nil,
        modifierFlags: NSEvent.ModifierFlags = [],
        optionWasConsumedForMeta: Bool = false
    ) -> Data? {
        guard !isRelease else { return nil }

        if modifierFlags.contains(.control),
           let eventCharacters,
           eventCharacters.count == 1,
           let scalar = eventCharacters.unicodeScalars.first,
           let controlByte = controlByte(for: scalar) {
            return Data([controlByte])
        }

        if let eventCharacters,
           eventCharacters.count == 1,
           let scalar = eventCharacters.unicodeScalars.first,
           scalar.value < 0x20 || scalar.value == 0x7f {
            let isPhysicalSpecialKey = keyCode.map {
                [36, 48, 51, 53].contains($0)
            } ?? false
            // Modified Enter/Tab/Backspace/Escape use CSI u below. A shifted
            // alphabetic control byte is already the terminal-correct payload
            // (for example Ctrl-Shift-R remains 0x12) and Ctrl-I/M/[/? must
            // not be confused with the physical special keys sharing bytes.
            let needsCSIU = isPhysicalSpecialKey
                && !modifierFlags.intersection([.shift, .option, .control]).isEmpty
            if needsCSIU { return nil }
            let raw = Data([UInt8(scalar.value)])
            return optionWasConsumedForMeta ? Data([0x1b]) + raw : raw
        }

        if let eventCharacters,
           eventCharacters.count == 1,
           let scalar = eventCharacters.unicodeScalars.first,
           functionKeyScalars.contains(scalar.value) {
            return nil
        }

        guard let text, !text.isEmpty else { return nil }
        let encoded = Data(text.utf8)

        // Ghostty's translation-modifier result is authoritative for
        // macos-option-as-alt. Text comparison is not: dead keys and input
        // methods may also transform text while Option remains ordinary
        // character input.
        if optionWasConsumedForMeta {
            return Data([0x1b]) + encoded
        }
        return encoded
    }

    // MARK: - Escape sequence encoding for special keys

    /// Generate the terminal escape sequence bytes for a key event.
    ///
    /// This replaces the old tmux token-based approach (`send-keys S-Enter`)
    /// which produced incorrect sequences for many modifier+key combinations.
    /// Instead we generate the exact escape bytes and send them via
    /// `send-keys -H` (hex-encoded).
    ///
    /// Encoding rules (legacy terminal protocol):
    /// - Arrow keys: `\e[1;<mod>A/B/C/D` (or `\e[A` etc. without modifiers)
    /// - Home/End: `\e[1;<mod>H/F` (or `\eOH`/`\eOF` without modifiers)
    /// - Insert/Delete/PageUp/PageDown: `\e[<code>;<mod>~` (or `\e[<code>~`)
    /// - F1-F4: `\eO<mod>P/Q/R/S` (or `\eOP` etc. without modifiers)
    /// - F5-F12: `\e[<code>;<mod>~` (or `\e[<code>~`)
    /// - Enter/Tab/BS/Esc with modifiers: CSI u `\e[<codepoint>;<mod>u`
    /// - Shift-Tab: `\e[Z` (standard backtab)
    static func escapeSequence(
        keyCode: UInt16,
        eventCharacters: String?,
        modifierFlags: NSEvent.ModifierFlags,
        applicationCursorKeys: Bool = false
    ) -> Data? {
        let mod = xtermModifierParam(modifierFlags)

        // Check for function-key scalars first (arrow keys, Home, End, etc.)
        if let eventCharacters,
           eventCharacters.count == 1,
           let scalar = eventCharacters.unicodeScalars.first,
           let seq = functionKeyScalarSequence(
               scalar.value,
               modifier: mod,
               applicationCursorKeys: applicationCursorKeys
           ) {
            return seq
        }

        // Check keyCode for keys that may not have function-key scalars
        // (e.g. from doCommandBySelector where eventCharacters may be nil)
        if let seq = keyCodeSequence(
            keyCode,
            modifier: mod,
            applicationCursorKeys: applicationCursorKeys
        ) {
            return seq
        }

        return nil
    }

    // MARK: - Private: escape sequence builders

    /// Convert NSEvent modifier flags to the xterm modifier parameter.
    /// xterm modifier = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0)
    /// Returns 0 when no modifiers are held (caller should omit the param).
    private static func xtermModifierParam(_ flags: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if flags.contains(.shift)   { m += 1 }
        if flags.contains(.option)  { m += 2 }
        if flags.contains(.control) { m += 4 }
        return m == 0 ? 0 : 1 + m
    }

    /// Escape sequence for macOS function-key Unicode scalars.
    private static func functionKeyScalarSequence(
        _ scalar: UInt32,
        modifier mod: Int,
        applicationCursorKeys: Bool
    ) -> Data? {
        switch scalar {
        // Arrow keys: \e[1;<mod>A/B/C/D or \e[A/B/C/D
        case 0xF700: return arrowSequence(0x41, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Up
        case 0xF701: return arrowSequence(0x42, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Down
        case 0xF703: return arrowSequence(0x43, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Right
        case 0xF702: return arrowSequence(0x44, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Left

        // Home/End: \e[1;<mod>H/F or \eOH/\eOF
        case 0xF729: return homeEndSequence(0x48, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Home
        case 0xF72B: return homeEndSequence(0x46, modifier: mod, applicationCursorKeys: applicationCursorKeys) // End

        // Tilde keys: \e[<code>;<mod>~ or \e[<code>~
        case 0xF727: return tildeSequence(2, modifier: mod)  // Insert
        case 0xF728: return tildeSequence(3, modifier: mod)  // Delete
        case 0xF72C: return tildeSequence(5, modifier: mod)  // PageUp
        case 0xF72D: return tildeSequence(6, modifier: mod)  // PageDown

        default: return nil
        }
    }

    /// Escape sequence from macOS keyCode (for keys without function-key scalars).
    private static func keyCodeSequence(
        _ keyCode: UInt16,
        modifier mod: Int,
        applicationCursorKeys: Bool
    ) -> Data? {
        switch keyCode {
        // Arrow keys (fallback when eventCharacters unavailable)
        case 126: return arrowSequence(0x41, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Up
        case 125: return arrowSequence(0x42, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Down
        case 124: return arrowSequence(0x43, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Right
        case 123: return arrowSequence(0x44, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Left

        // Home/End
        case 115: return homeEndSequence(0x48, modifier: mod, applicationCursorKeys: applicationCursorKeys) // Home
        case 119: return homeEndSequence(0x46, modifier: mod, applicationCursorKeys: applicationCursorKeys) // End

        // Tilde keys
        case 114: return tildeSequence(2, modifier: mod)  // Insert
        case 117: return tildeSequence(3, modifier: mod)  // Delete
        case 116: return tildeSequence(5, modifier: mod)  // PageUp
        case 121: return tildeSequence(6, modifier: mod)  // PageDown

        // Enter (0x0d), Tab (0x09), Backspace (0x7f), Escape (0x1b)
        // With modifiers: CSI u encoding \e[<codepoint>;<mod>u
        // Without modifiers: return nil — the raw byte is already sent by
        // inputData() or doCommand(), so we must not duplicate it here.
        case 36: // Enter
            if mod > 0 { return csiU(13, modifier: mod) }
            return nil
        case 48: // Tab
            // Shift-Tab is special: \e[Z (standard backtab)
            if mod == 2 { return Data([0x1b, 0x5b, 0x5a]) }
            if mod > 0 { return csiU(9, modifier: mod) }
            return nil
        case 51: // Backspace
            if mod > 0 { return csiU(127, modifier: mod) }
            return nil
        case 53: // Escape
            if mod > 0 { return csiU(27, modifier: mod) }
            return nil

        // Function keys F1-F4: SS3 sequences \eO<mod>P/Q/R/S
        case 122: return ss3FunctionKey(0x50, modifier: mod) // F1
        case 120: return ss3FunctionKey(0x51, modifier: mod) // F2
        case  99: return ss3FunctionKey(0x52, modifier: mod) // F3
        case 118: return ss3FunctionKey(0x53, modifier: mod) // F4

        // Function keys F5-F12: tilde sequences
        case  96: return tildeSequence(15, modifier: mod) // F5
        case  97: return tildeSequence(17, modifier: mod) // F6
        case  98: return tildeSequence(18, modifier: mod) // F7
        case 100: return tildeSequence(19, modifier: mod) // F8
        case 101: return tildeSequence(20, modifier: mod) // F9
        case 109: return tildeSequence(21, modifier: mod) // F10
        case 103: return tildeSequence(23, modifier: mod) // F11
        case 111: return tildeSequence(24, modifier: mod) // F12

        default: return nil
        }
    }

    /// Arrow key, honoring DEC cursor-key application mode for unmodified input.
    private static func arrowSequence(
        _ letter: UInt8,
        modifier mod: Int,
        applicationCursorKeys: Bool
    ) -> Data {
        if mod > 0 {
            return Data([0x1b, 0x5b, 0x31, 0x3b] + Array(String(mod).utf8) + [letter])
        }
        return Data([0x1b, applicationCursorKeys ? 0x4f : 0x5b, letter])
    }

    /// Home/End, honoring DEC cursor-key application mode for unmodified input.
    private static func homeEndSequence(
        _ letter: UInt8,
        modifier mod: Int,
        applicationCursorKeys: Bool
    ) -> Data {
        if mod > 0 {
            return Data([0x1b, 0x5b, 0x31, 0x3b] + Array(String(mod).utf8) + [letter])
        }
        return Data([0x1b, applicationCursorKeys ? 0x4f : 0x5b, letter])
    }

    /// Tilde key: `\e[<code>;<mod>~` or `\e[<code>~`
    private static func tildeSequence(_ code: Int, modifier mod: Int) -> Data {
        if mod > 0 {
            return Data(Array("\u{1b}[\(code);\(mod)~".utf8))
        }
        return Data(Array("\u{1b}[\(code)~".utf8))
    }

    /// SS3 function key (F1-F4): `\e[1;<mod>P` or `\eOP`
    private static func ss3FunctionKey(_ letter: UInt8, modifier mod: Int) -> Data {
        if mod > 0 {
            // With modifier, use CSI form: \e[1;<mod>P
            return Data([0x1b, 0x5b, 0x31, 0x3b] + Array(String(mod).utf8) + [letter])
        }
        return Data([0x1b, 0x4f, letter])
    }

    /// CSI u encoding: `\e[<codepoint>;<mod>u`
    private static func csiU(_ codepoint: Int, modifier mod: Int) -> Data {
        return Data(Array("\u{1b}[\(codepoint);\(mod)u".utf8))
    }

    // MARK: - Private: control byte mapping

    private static func controlByte(for scalar: UnicodeScalar) -> UInt8? {
        let value = scalar.value
        if value >= 0x61, value <= 0x7a {
            return UInt8(value - 0x60)
        }
        if value >= 0x41, value <= 0x5a {
            return UInt8(value - 0x40)
        }

        switch scalar {
        case "@", " ":
            return 0x00
        case "[":
            return 0x1b
        case "\\":
            return 0x1c
        case "]":
            return 0x1d
        case "^":
            return 0x1e
        case "_":
            return 0x1f
        case "?":
            return 0x7f
        default:
            return nil
        }
    }
}

enum AttachedTmuxInputRouter {
    // Diverges from fantastty: fantastty's `bindingFlags` parameter is typed
    // `Ghostty.Input.BindingFlags?`, a Swift OptionSet wrapper that doesn't
    // exist in GhosthubTerminal. It's unused inside this function in
    // fantastty too (`_ = bindingFlags`), so it's kept here only for call-site
    // parity, typed as ghosthub's raw `ghostty_binding_flags_e?`.
    static func shouldHandleLocally(
        bindingFlags: ghostty_binding_flags_e?,
        event: NSEvent
    ) -> Bool {
        // In attached tmux mode, route keys remotely by default so terminal apps
        // (vim, shell readline, etc.) receive full input fidelity. Keep App-level
        // command shortcuts local.
        if event.modifierFlags.contains(.command) {
            return true
        }
        _ = bindingFlags
        return false
    }
}
