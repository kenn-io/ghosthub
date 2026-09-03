import AppKit

@MainActor
protocol TerminalPasteboard: AnyObject {
    func string(forType dataType: NSPasteboard.PasteboardType) -> String?
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data?

    @discardableResult
    func clearContents() -> Int

    @discardableResult
    func declareTypes(
        _ newTypes: [NSPasteboard.PasteboardType],
        owner newOwner: Any?
    ) -> Int

    @discardableResult
    func setString(
        _ string: String,
        forType dataType: NSPasteboard.PasteboardType
    ) -> Bool
}

extension NSPasteboard: TerminalPasteboard {}

@MainActor
enum TerminalPasteboardAccess {
    static var current: any TerminalPasteboard = NSPasteboard.general

    static func reset() {
        current = NSPasteboard.general
    }
}
