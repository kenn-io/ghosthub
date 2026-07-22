import Testing
@testable import GhosthubTerminal

@MainActor
struct ClipboardAccessPolicyTests {
    @Test("blocked surfaces never expose clipboard contents")
    func blockedReadReturnsEmptyContents() {
        var didRead = false
        func readClipboard() -> String? {
            didRead = true
            return "local secret"
        }

        #expect(
            GhosttyRuntime.clipboardReadContents(
                blocked: true,
                contents: readClipboard()
            ).isEmpty
        )
        #expect(!didRead)
    }

    @Test("ordinary surfaces retain clipboard reads")
    func ordinaryReadReturnsClipboardContents() {
        #expect(
            GhosttyRuntime.clipboardReadContents(
                blocked: false,
                contents: "local text"
            ) == "local text"
        )
    }

    @Test("remote OSC 52 writes are rejected before touching the pasteboard")
    func blockedOSC52WriteIsRejected() {
        let entries = [
            GhosttyRuntime.ClipboardWriteEntry(
                mime: "text/plain",
                data: "remote payload"
            ),
            GhosttyRuntime.ClipboardWriteEntry(
                mime: GhosttyRuntime.osc52ClipboardWriteMIME,
                data: ""
            ),
        ]

        #expect(
            GhosttyRuntime.acceptedClipboardWriteEntries(
                blocked: true,
                entries: entries
            ) == nil
        )
    }

    @Test("user-initiated copy remains available on remote surfaces")
    func blockedSurfaceAcceptsOrdinaryCopy() {
        let copy = GhosttyRuntime.ClipboardWriteEntry(
            mime: "text/plain",
            data: "selected text"
        )

        #expect(
            GhosttyRuntime.acceptedClipboardWriteEntries(
                blocked: true,
                entries: [copy]
            ) == [copy]
        )
    }

    @Test("local OSC 52 writes discard the private origin marker")
    func ordinarySurfaceAcceptsOSC52WithoutMarker() {
        let payload = GhosttyRuntime.ClipboardWriteEntry(
            mime: "text/plain",
            data: "local payload"
        )
        let marker = GhosttyRuntime.ClipboardWriteEntry(
            mime: GhosttyRuntime.osc52ClipboardWriteMIME,
            data: ""
        )

        #expect(
            GhosttyRuntime.acceptedClipboardWriteEntries(
                blocked: false,
                entries: [payload, marker]
            ) == [payload]
        )
    }
}
