import Testing
import GhosthubWorkspace

@Suite("New Zellij session naming")
struct ZellijSessionNameTests {
    @Test(
        "valid names follow Zellij's path-safe session boundary",
        arguments: [
            "api",
            "release work",
            "déploiement",
            "-",
            "api-help",
            "help wanted",
            "options-api",
        ]
    )
    func validNames(_ name: String) {
        #expect(ZellijSessionName.isValid(name))
    }

    @Test(
        "invalid names are rejected before launch",
        arguments: [
            "",
            "   ",
            ".",
            "..",
            "team/api",
            "api\nworker",
            "-release",
            "--create",
            "help",
            "options"
        ]
    )
    func invalidNames(_ name: String) {
        #expect(!ZellijSessionName.isValid(name))
    }
}
