import Testing
@testable import GhosthubUI

struct TerminalFontFamilyOptionsTests {
    @Test("keeps an unavailable configured family selectable")
    func keepsUnavailableConfiguredFamily() {
        #expect(
            TerminalFontFamilyOptions.families(
                installedFixedPitch: ["SF Mono"],
                configured: "  Berkeley Mono  "
            ) == ["Berkeley Mono", "SF Mono"]
        )
    }
}
