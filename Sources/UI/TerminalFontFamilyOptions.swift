import Foundation

enum TerminalFontFamilyOptions {
    static func families(
        installedFixedPitch: [String],
        configured: String
    ) -> [String] {
        var families = Set(installedFixedPitch)
        let configured = configured.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if !configured.isEmpty {
            families.insert(configured)
        }
        return families.sorted()
    }
}
