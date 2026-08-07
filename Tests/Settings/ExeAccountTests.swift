import Testing
@testable import GhosthubSettings

@Suite("exe.dev account settings")
struct ExeAccountTests {
    @Test("stored accounts preserve destinations while discovery rejects ambiguity")
    func sanitizesAccounts() {
        let input = [
            ExeAccount(
                configKey: " personal ",
                name: " Personal ",
                sshDestination: " exe.dev "
            ),
            ExeAccount(
                configKey: "personal",
                name: "Duplicate",
                sshDestination: "other"
            ),
            ExeAccount(
                configKey: "missing-address",
                name: "Missing",
                sshDestination: ""
            ),
            ExeAccount(
                configKey: "duplicate-destination",
                name: "Duplicate destination",
                sshDestination: " exe.dev "
            ),
            ExeAccount(
                configKey: "disabled-duplicate",
                name: "Disabled duplicate",
                sshDestination: "exe.dev",
                isEnabled: false
            ),
        ]

        #expect(ExeAccountSanitizer.storedAccounts(input) == [
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev"
            ),
            ExeAccount(
                configKey: "duplicate-destination",
                name: "Duplicate destination",
                sshDestination: "exe.dev"
            ),
            ExeAccount(
                configKey: "disabled-duplicate",
                name: "Disabled duplicate",
                sshDestination: "exe.dev",
                isEnabled: false
            ),
        ])
        #expect(ExeAccountSanitizer.discoverableAccounts(input) == [
            ExeAccount(
                configKey: "disabled-duplicate",
                name: "Disabled duplicate",
                sshDestination: "exe.dev",
                isEnabled: false
            ),
        ])
        #expect(ExeAccountSanitizer.duplicateEnabledDestinations([
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev"
            ),
            ExeAccount(
                configKey: "work",
                name: "Work",
                sshDestination: " exe.dev "
            ),
        ]) == ["exe.dev"])
    }
}
