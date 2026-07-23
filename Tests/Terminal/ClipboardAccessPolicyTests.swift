import Testing
@testable import GhosthubTerminal
import GhosttyKit

@MainActor
struct ClipboardAccessPolicyTests {
    @Test("ordinary clipboard reads supply local contents")
    func ordinaryReadSuppliesClipboardContents() {
        #expect(
            LibghosttyRuntime.clipboardReadContents(
                blocked: false,
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
                contents: "local text"
            ) == "local text"
        )
    }

    @Test("remote clipboard reads do not evaluate the pasteboard supplier")
    func blockedReadNeverTouchesClipboardContents() {
        var didReadPasteboard = false

        let contents = LibghosttyRuntime.clipboardReadContents(
            blocked: true,
            request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
            contents: {
                didReadPasteboard = true
                return "local secret"
            }()
        )

        #expect(contents.isEmpty)
        #expect(!didReadPasteboard)
    }

    @Test("a semantic paste request may supply clipboard contents")
    func semanticPasteMayReadClipboardContents() {
        #expect(
            LibghosttyRuntime.clipboardReadContents(
                blocked: true,
                request: GHOSTTY_CLIPBOARD_REQUEST_PASTE,
                contents: "user-selected text"
            ) == "user-selected text"
        )
    }

    @Test("remote surfaces allow explicit paste confirmation")
    func blockedSurfaceAllowsPaste() {
        #expect(
            LibghosttyRuntime.allowsClipboardConfirmation(
                blocked: true,
                request: GHOSTTY_CLIPBOARD_REQUEST_PASTE
            )
        )
    }

    @Test("remote surfaces deny OSC 52 clipboard reads")
    func blockedSurfaceDeniesOSC52Read() {
        #expect(
            !LibghosttyRuntime.allowsClipboardConfirmation(
                blocked: true,
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
            )
        )
    }

    @Test("ordinary surfaces retain OSC 52 clipboard behavior")
    func ordinarySurfaceAllowsOSC52Read() {
        #expect(
            LibghosttyRuntime.allowsClipboardConfirmation(
                blocked: false,
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
            )
        )
    }

    @Test("remote OSC 52 writes are rejected before touching the pasteboard")
    func blockedOSC52WriteIsRejected() {
        let entries = [
            LibghosttyRuntime.ClipboardWriteEntry(
                mime: "text/plain",
                data: "remote payload"
            ),
            LibghosttyRuntime.ClipboardWriteEntry(
                mime: LibghosttyRuntime.osc52ClipboardWriteMIME,
                data: ""
            ),
        ]

        #expect(
            LibghosttyRuntime.acceptedClipboardWriteEntries(
                blocked: true,
                entries: entries
            ) == nil
        )
    }

    @Test("user-initiated copy remains available on remote surfaces")
    func blockedSurfaceAcceptsOrdinaryCopy() {
        let copy = LibghosttyRuntime.ClipboardWriteEntry(
            mime: "text/plain",
            data: "selected text"
        )

        #expect(
            LibghosttyRuntime.acceptedClipboardWriteEntries(
                blocked: true,
                entries: [copy]
            ) == [copy]
        )
    }

    @Test("local OSC 52 writes discard the private origin marker")
    func ordinarySurfaceAcceptsOSC52WithoutMarker() {
        let payload = LibghosttyRuntime.ClipboardWriteEntry(
            mime: "text/plain",
            data: "local payload"
        )
        let marker = LibghosttyRuntime.ClipboardWriteEntry(
            mime: LibghosttyRuntime.osc52ClipboardWriteMIME,
            data: ""
        )

        #expect(
            LibghosttyRuntime.acceptedClipboardWriteEntries(
                blocked: false,
                entries: [payload, marker]
            ) == [payload]
        )
    }
}
