import Foundation

extension UUID {
    /// Creates a stable, predictable UUID from a single character.
    /// Useful for readable test assertions involving identifiers.
    public static func predictable(_ letter: Character) -> UUID {
        let code = String(
            format: "%02X",
            letter.unicodeScalars.first!.value
        )
        let seg8 = String(repeating: code, count: 4)
        let seg4 = String(repeating: code, count: 2)
        let seg12 = String(repeating: code, count: 6)
        return UUID(
            uuidString: "\(seg8)-\(seg4)-\(seg4)-\(seg4)-\(seg12)"
        )!
    }
}
