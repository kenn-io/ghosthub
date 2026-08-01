import Testing
@testable import GhosthubApp

@Suite("Quit policy")
struct QuitPolicyTests {
    @Test(arguments: [true, false])
    func followsTheUserSetting(_ enabled: Bool) {
        #expect(
            QuitPolicy.needsConfirmation(confirmBeforeQuitting: enabled)
                == enabled
        )
    }
}
