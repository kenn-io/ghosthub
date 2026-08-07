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

    @Test("persistence reconciles invalid accounts independently")
    func reconcilesPersistenceByAccount() {
        let personal = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )
        let work = ExeAccount(
            configKey: "work",
            name: "Work",
            sshDestination: "work-exe"
        )
        let removed = ExeAccount(
            configKey: "removed",
            name: "Removed",
            sshDestination: "removed-exe"
        )
        let added = ExeAccount(
            configKey: "added",
            name: "Added",
            sshDestination: "added-exe"
        )

        #expect(ExeAccountSanitizer.accountsForPersistence(
            [
                ExeAccount(
                    configKey: "personal",
                    name: "Renamed",
                    sshDestination: "exe.dev"
                ),
                ExeAccount(
                    configKey: "work",
                    name: "",
                    sshDestination: "work-exe"
                ),
                added,
            ],
            previous: [personal, work, removed]
        ) == [
            ExeAccount(
                configKey: "personal",
                name: "Renamed",
                sshDestination: "exe.dev"
            ),
            work,
            added,
        ])

        #expect(ExeAccountSanitizer.accountsForPersistence(
            [
                personal,
                ExeAccount(
                    configKey: "work",
                    name: "Work",
                    sshDestination: "exe.dev"
                ),
                added,
            ],
            previous: [personal, work]
        ) == [personal, work, added])
    }
}
