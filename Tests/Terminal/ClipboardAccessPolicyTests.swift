import Testing
@testable import GhosthubTerminal
import GhosttyKit

@MainActor
struct ClipboardAccessPolicyTests {
    @Test("ordinary clipboard reads supply local contents")
    func ordinaryReadSuppliesClipboardContents() {
        #expect(
            GhosttyRuntime.clipboardReadContents(
                blocked: false,
                contents: "local text"
            ) == "local text"
        )
    }

    @Test("remote clipboard reads do not evaluate the pasteboard supplier")
    func blockedReadNeverTouchesClipboardContents() {
        var didReadPasteboard = false

        let contents = GhosttyRuntime.clipboardReadContents(
            blocked: true,
            contents: {
                didReadPasteboard = true
                return "local secret"
            }()
        )

        #expect(contents.isEmpty)
        #expect(!didReadPasteboard)
    }

    @Test("a one-shot user paste may supply clipboard contents")
    func explicitPasteMayReadClipboardContents() {
        #expect(
            GhosttyRuntime.clipboardReadContents(
                blocked: true,
                explicitlyAuthorized: true,
                contents: "user-selected text"
            ) == "user-selected text"
        )
    }

    @Test("remote surfaces allow explicit paste confirmation")
    func blockedSurfaceAllowsPaste() {
        #expect(
            GhosttyRuntime.allowsClipboardConfirmation(
                blocked: true,
                request: GHOSTTY_CLIPBOARD_REQUEST_PASTE
            )
        )
    }

    @Test("remote surfaces deny OSC 52 clipboard reads")
    func blockedSurfaceDeniesOSC52Read() {
        #expect(
            !GhosttyRuntime.allowsClipboardConfirmation(
                blocked: true,
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
            )
        )
    }

    @Test("ordinary surfaces retain OSC 52 clipboard behavior")
    func ordinarySurfaceAllowsOSC52Read() {
        #expect(
            GhosttyRuntime.allowsClipboardConfirmation(
                blocked: false,
                request: GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ
            )
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
