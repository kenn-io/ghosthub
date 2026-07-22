import Testing
@testable import GhosthubUI

@Suite("Tmux session names")
struct NewTmuxSessionSheetTests {
    @Test(
        "validates tmux session names",
        arguments: [
            ("docbank", true),
            ("  release work  ", true),
            ("", false),
            ("   ", false),
            ("has.period", false),
            ("has:colon", false),
            ("has\nnewline", false),
        ]
    )
    func validates(name: String, expected: Bool) {
        #expect(TmuxSessionName.isValid(name) == expected)
    }
}
