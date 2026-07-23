// Ported from fantastty (https://github.com/blaine/fantastty), commit
// 60d248d0, FantasttyTests/TmuxControlClientTests.swift (the
// AttachedTmuxInput* cases). Copyright (c) 2026 Blaine Cook —
// MIT License (LICENSES/fantastty-MIT.txt).
//
// Kept as XCTest per repo convention for ported test suites (not migrated
// to Swift Testing).

import AppKit
import GhosttyKit
import XCTest
@testable import GhosthubTerminal

final class AttachedTmuxInputTests: XCTestCase {

    // MARK: - Primary encoding: raw bytes for printable text and control chars

    func testAttachedTmuxInputPrefersRawControlCharactersFromEvent() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "c",
            eventCharacters: "\u{03}"
        )

        XCTAssertEqual(data, Data([0x03]))
    }

    func testAttachedTmuxInputUsesPrintableTextWhenNoControlCharacterExists() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "ls",
            eventCharacters: "ls"
        )

        XCTAssertEqual(data, Data("ls".utf8))
    }

    func testAttachedTmuxInputMapsControlModifiedPrintableCharacterToControlByte() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "r",
            eventCharacters: "r",
            modifierFlags: [.control]
        )

        XCTAssertEqual(data, Data([0x12]))
    }

    func testAttachedTmuxInputMapsControlOpenBracketToEscapeByte() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "[",
            eventCharacters: "[",
            modifierFlags: [.control]
        )

        XCTAssertEqual(data, Data([0x1b]))
    }

    func testAttachedTmuxInputIgnoresReleaseEvents() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: true,
            text: nil,
            eventCharacters: "\u{7f}"
        )

        XCTAssertNil(data)
    }

    func testAttachedTmuxInputSkipsFunctionKeyUnicodeForHexPath() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "\u{f700}",
            eventCharacters: "\u{f700}"
        )

        XCTAssertNil(data)
    }

    // MARK: - Escape sequence encoding

    func testEscapeSequenceArrowUpUnmodified() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 126,
            eventCharacters: "\u{f700}",
            modifierFlags: []
        )
        // \e[A
        XCTAssertEqual(data, Data([0x1b, 0x5b, 0x41]))
    }

    func testEscapeSequenceArrowUpInApplicationCursorMode() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 126,
            eventCharacters: "\u{f700}",
            modifierFlags: [],
            applicationCursorKeys: true
        )
        XCTAssertEqual(data, Data([0x1b, 0x4f, 0x41]))
    }

    func testEscapeSequenceArrowLeftByKeyCodeFallback() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 123,
            eventCharacters: nil,
            modifierFlags: []
        )
        // \e[D
        XCTAssertEqual(data, Data([0x1b, 0x5b, 0x44]))
    }

    func testEscapeSequenceArrowRightWithControlAndOption() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 124,
            eventCharacters: "\u{f703}",
            modifierFlags: [.control, .option]
        )
        // \e[1;7C  (modifier = 1 + 4 + 2 = 7)
        XCTAssertEqual(data, Data(Array("\u{1b}[1;7C".utf8)))
    }

    func testEscapeSequenceShiftEnterProducesCsiU() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 36,
            eventCharacters: nil,
            modifierFlags: [.shift]
        )
        // \e[13;2u
        XCTAssertEqual(data, Data(Array("\u{1b}[13;2u".utf8)))
    }

    func testEscapeSequenceShiftTabProducesBacktab() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 48,
            eventCharacters: nil,
            modifierFlags: [.shift]
        )
        // \e[Z
        XCTAssertEqual(data, Data([0x1b, 0x5b, 0x5a]))
    }

    func testEscapeSequenceUnmodifiedEnterUsesRawInputPath() {
        let escapeData = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 36,
            eventCharacters: nil,
            modifierFlags: []
        )
        let inputData = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "\r",
            eventCharacters: "\r"
        )
        XCTAssertNil(escapeData)
        XCTAssertEqual(inputData, Data([0x0d]))
    }

    func testEscapeSequenceF1Unmodified() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 122,
            eventCharacters: nil,
            modifierFlags: []
        )
        // \eOP
        XCTAssertEqual(data, Data([0x1b, 0x4f, 0x50]))
    }

    func testEscapeSequenceF5WithShift() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 96,
            eventCharacters: nil,
            modifierFlags: [.shift]
        )
        // \e[15;2~
        XCTAssertEqual(data, Data(Array("\u{1b}[15;2~".utf8)))
    }

    func testEscapeSequenceHomeUnmodified() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 115,
            eventCharacters: "\u{f729}",
            modifierFlags: []
        )
        // \e[H
        XCTAssertEqual(data, Data([0x1b, 0x5b, 0x48]))
    }

    func testEscapeSequenceHomeInApplicationCursorMode() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 115,
            eventCharacters: "\u{f729}",
            modifierFlags: [],
            applicationCursorKeys: true
        )
        XCTAssertEqual(data, Data([0x1b, 0x4f, 0x48]))
    }

    func testTerminalModeTrackerHandlesSplitDECCKMSequences() {
        var tracker = AttachedTmuxTerminalModeTracker()
        tracker.consume(Data([0x1b, 0x5b, 0x3f]))
        tracker.consume(Data("1h".utf8))
        XCTAssertTrue(tracker.applicationCursorKeys)

        tracker.consume(Data([0x1b, 0x63]))
        XCTAssertFalse(tracker.applicationCursorKeys)

        tracker.consume(Data("prefix\u{1b}[?1h".utf8))
        XCTAssertTrue(tracker.applicationCursorKeys)
        tracker.consume(Data("\u{1b}[?1".utf8))
        tracker.consume(Data("l".utf8))
        XCTAssertFalse(tracker.applicationCursorKeys)

        tracker.consume(Data("\u{1b}[?1h\u{1b}[!".utf8))
        XCTAssertTrue(tracker.applicationCursorKeys)
        tracker.consume(Data("p".utf8))
        XCTAssertFalse(tracker.applicationCursorKeys)
    }

    func testTerminalModeTrackerDoesNotTreatUTF8ContinuationAsC1CSI() {
        var tracker = AttachedTmuxTerminalModeTracker()

        tracker.consume(Data([0xc2, 0x9b]) + Data("?1h".utf8))

        XCTAssertFalse(tracker.applicationCursorKeys)
    }

    func testEscapeSequenceDeleteWithControl() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 117,
            eventCharacters: "\u{f728}",
            modifierFlags: [.control]
        )
        // \e[3;5~
        XCTAssertEqual(data, Data(Array("\u{1b}[3;5~".utf8)))
    }

    func testEscapeSequenceUnknownKeyReturnsNil() {
        let data = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 0, // 'a' keyCode
            eventCharacters: "a",
            modifierFlags: []
        )
        XCTAssertNil(data)
    }

    /// Diverges from fantastty: fantastty calls `try XCTUnwrap(event)` inline
    /// inside a non-`throws` test function, which doesn't compile in Swift.
    /// `throws` is added here and the `try XCTUnwrap` wraps the whole
    /// `NSEvent.keyEvent(...)` construction instead; assertions are unchanged.
    func testAttachedTmuxEventCharactersReturnsCharactersForKeyDown() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )

        XCTAssertEqual(
            AttachedTmuxInputEncoder.eventCharacters(for: event),
            "a"
        )
    }

    /// Diverges from fantastty: same `throws`/`try XCTUnwrap` fix as
    /// testAttachedTmuxEventCharactersReturnsCharactersForKeyDown above.
    func testAttachedTmuxEventCharactersSkipsFlagsChangedEvents() throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: 0x37
            )
        )

        XCTAssertNil(AttachedTmuxInputEncoder.eventCharacters(for: event))
    }

    func testAttachedTmuxRouterKeepsCommandShortcutsLocal() throws {
        let commandEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "k",
                charactersIgnoringModifiers: "k",
                isARepeat: false,
                keyCode: 40
            )
        )

        XCTAssertTrue(
            AttachedTmuxInputRouter.shouldHandleLocally(
                bindingFlags: nil,
                event: commandEvent
            )
        )
    }

    // MARK: - Roborev 1331 adjudication (encoder-level pinning)

    //
    // See Tests/TerminalSmoke/TerminalSurfaceViewInputTests.swift for the
    // end-to-end (real NSEvent dispatch through TerminalSurfaceView.keyAction)
    // versions of these cases, and .superpowers/sdd/roborev-checkpoint-A-report.md
    // for the full adjudication writeup.

    /// Finding A, macOS-default sub-case (macos-option-as-alt disabled):
    /// real Option-D events carry eventCharacters == text == "∂" (verified
    /// via CGEventCreateKeyboardEvent probe), which the encoder passes
    /// through unchanged. This matches standard macOS terminal behavior
    /// (Option-D sends "∂" unless the app is configured to treat Option as
    /// Meta) — refuted, no bug.
    func testAttachedTmuxInputOptionDWithoutMetaTranslationSendsPrintableDiaeresis() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "∂",
            eventCharacters: "∂",
            modifierFlags: [.option]
        )

        XCTAssertEqual(data, Data("∂".utf8))
    }

    /// With macos-option-as-alt enabled, translated text differs from the
    /// original Option glyph. Pane routing must preserve libghostty's Meta prefix.
    func testAttachedTmuxInputOptionDWithMetaTranslationSendsEscapeD() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "d",
            eventCharacters: "∂",
            modifierFlags: [.option],
            optionWasConsumedForMeta: true
        )

        XCTAssertEqual(data, Data([0x1b, 0x64]))
    }

    func testAttachedTmuxInputChangedOptionTextWithoutConsumedMetaStaysText() {
        let data = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "é",
            eventCharacters: "´",
            modifierFlags: [.option],
            optionWasConsumedForMeta: false
        )

        XCTAssertEqual(data, Data("é".utf8))
    }

    func testAttachedTmuxInputControlEnterUsesCsiU() {
        let raw = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "\r",
            eventCharacters: "\r",
            keyCode: 36,
            modifierFlags: [.control]
        )
        let encoded = AttachedTmuxInputEncoder.escapeSequence(
            keyCode: 36,
            eventCharacters: "\r",
            modifierFlags: [.control]
        )

        XCTAssertNil(raw)
        XCTAssertEqual(encoded, Data("\u{1b}[13;5u".utf8))
    }

    func testAttachedTmuxInputControlAliasesRemainRawControlBytes() {
        let cases: [(keyCode: UInt16, character: String, byte: UInt8)] = [
            (34, "\t", 0x09),   // Ctrl-I, not physical Tab (48)
            (46, "\r", 0x0d),   // Ctrl-M, not physical Enter (36)
            (33, "\u{1b}", 0x1b), // Ctrl-[, not physical Escape (53)
            (44, "\u{7f}", 0x7f), // Ctrl-?, not physical Backspace (51)
        ]
        for item in cases {
            let data = AttachedTmuxInputEncoder.inputData(
                isRelease: false,
                text: item.character,
                eventCharacters: item.character,
                keyCode: item.keyCode,
                modifierFlags: [.control]
            )
            XCTAssertEqual(data, Data([item.byte]))
        }
    }

    func testAttachedTmuxInputControlShiftLetterPreservesControlByte() {
        let inputResult = AttachedTmuxInputEncoder.inputData(
            isRelease: false,
            text: "R",
            eventCharacters: "\u{12}",
            keyCode: 15,
            modifierFlags: [.control, .shift]
        )
        XCTAssertEqual(inputResult, Data([0x12]))
    }

    func testAttachedTmuxRouterRoutesNonCommandKeysRemotelyEvenWhenConsumed() throws {
        let plainEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: "r",
                charactersIgnoringModifiers: "r",
                isARepeat: false,
                keyCode: 15
            )
        )

        let consumed = ghostty_binding_flags_e(
            rawValue: GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue
        )
        XCTAssertFalse(
            AttachedTmuxInputRouter.shouldHandleLocally(
                bindingFlags: consumed,
                event: plainEvent
            )
        )
    }
}
