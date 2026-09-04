import AppKit
import Foundation

public struct TerminalClipboardImage: Equatable, Sendable {
    public let pngData: Data

    public init(pngData: Data) {
        self.pngData = pngData
    }

    @MainActor
    static func read(from pasteboard: any TerminalPasteboard) -> Self? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return Self(pngData: png)
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              !png.isEmpty
        else { return nil }
        return Self(pngData: png)
    }
}
