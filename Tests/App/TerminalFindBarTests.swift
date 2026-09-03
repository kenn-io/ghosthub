import AppKit
import GhosthubTerminalSupport
import Testing
@testable import GhosthubApp

@Suite("Terminal Find bar")
@MainActor
struct TerminalFindBarTests {
    @Test("result status stays compact")
    func statusText() {
        #expect(TerminalFindBar.statusText(for: .idle) == nil)
        #expect(TerminalFindBar.statusText(for: .noMatch) == "No matches")
        #expect(TerminalFindBar.statusText(
            for: .match(total: 5, selected: nil)
        ) == "5 matches")
        #expect(TerminalFindBar.statusText(
            for: .match(total: 5, selected: 2)
        ) == "2 of 5")
        #expect(TerminalFindBar.statusText(
            for: .match(total: nil, selected: nil)
        ) == nil)
    }

    @Test("field commands match Ghostty-style navigation")
    func fieldCommands() {
        #expect(TerminalFindBar.fieldCommand(
            selector: #selector(NSResponder.insertNewline(_:)),
            shift: false
        ) == .next)
        #expect(TerminalFindBar.fieldCommand(
            selector: #selector(NSResponder.insertNewline(_:)),
            shift: true
        ) == .previous)
        #expect(TerminalFindBar.fieldCommand(
            selector: #selector(NSResponder.cancelOperation(_:)),
            shift: false
        ) == .close)
        #expect(TerminalFindBar.fieldCommand(
            selector: #selector(NSResponder.moveLeft(_:)),
            shift: false
        ) == nil)
    }
}
