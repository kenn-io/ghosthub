import Foundation
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

    @Test("remote clipboard reads do not evaluate the pasteboard supplier", arguments: [
        GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ,
        GHOSTTY_CLIPBOARD_REQUEST_KITTY_READ,
        GHOSTTY_CLIPBOARD_REQUEST_LIST,
    ])
    func blockedReadNeverTouchesClipboardContents(request: ghostty_clipboard_request_e) {
        var didReadPasteboard = false

        let contents = LibghosttyRuntime.clipboardReadContents(
            blocked: true,
            request: request,
            contents: {
                didReadPasteboard = true
                return "local secret"
            }()
        )

        #expect(contents.isEmpty)
        #expect(!didReadPasteboard)
    }

    @Test("clipboard callbacks copy exactly the supplied byte length")
    func clipboardBytesUseExplicitLength() {
        // No terminator at the declared end, and invalid UTF-8 after it.
        let bytes: [UInt8] = [0x61, 0x00, 0x62, 0xFF]
        let entries = "text/plain".withCString { mime in
            bytes.withUnsafeBytes { buffer in
                var content = ghostty_clipboard_content_s(
                    mime: mime,
                    data: buffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                    len: 3
                )
                return LibghosttyRuntime.clipboardWriteEntries(&content, count: 1)
            }
        }
        #expect(entries == [.init(mime: "text/plain", data: "a\0b")])
    }

    @Test("non-text clipboard bytes are not converted into corrupt text")
    func invalidClipboardTextIsRejected() {
        let bytes: [UInt8] = [0xFF]
        let entries = "image/png".withCString { mime in
            bytes.withUnsafeBytes { buffer in
                var content = ghostty_clipboard_content_s(
                    mime: mime,
                    data: buffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                    len: 1
                )
                return LibghosttyRuntime.clipboardWriteEntries(&content, count: 1)
            }
        }
        #expect(entries.isEmpty)
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

    @Test("OSC 52 writes discard the private origin marker")
    func osc52WriteDiscardsOriginMarker() {
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
                entries
            ) == [entries[0]]
        )
    }

    @Test("user-initiated copy remains available")
    func acceptsOrdinaryCopy() {
        let copy = LibghosttyRuntime.ClipboardWriteEntry(
            mime: "text/plain",
            data: "selected text"
        )

        #expect(
            LibghosttyRuntime.acceptedClipboardWriteEntries(
                [copy]
            ) == [copy]
        )
    }
}
