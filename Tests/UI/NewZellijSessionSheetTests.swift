import Testing
@testable import GhosthubUI

@Suite("New Zellij session naming")
struct NewZellijSessionSheetTests {
    @Test(
        "valid names follow Zellij's path-safe session boundary",
        arguments: ["api", "release work", "déploiement"]
    )
    func validNames(_ name: String) {
        #expect(ZellijSessionName.isValid(name))
    }

    @Test(
        "invalid names are rejected before launch",
        arguments: ["", "   ", ".", "..", "team/api", "api\nworker"]
    )
    func invalidNames(_ name: String) {
        #expect(!ZellijSessionName.isValid(name))
    }
}
