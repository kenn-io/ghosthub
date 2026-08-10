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

    @Test("tag filters normalize to a canonical, deduplicated list")
    func normalizesTagFilters() {
        #expect(ExeTagFilter.tags(in: "  dev,,prod dev  ,DEV ")
            == ["dev", "prod"])
        #expect(ExeTagFilter.normalized(" prod ,dev") == "prod, dev")
        #expect(ExeTagFilter.normalized("   ").isEmpty)

        let stored = ExeAccountSanitizer.storedAccounts([
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev",
                tagFilter: " dev,  prod dev "
            ),
        ])

        #expect(stored.first?.tagFilter == "dev, prod")
        #expect(ExeAccountSanitizer.accountsForPersistence(
            [ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev",
                tagFilter: "dev,,prod"
            )],
            previous: []
        ).first?.tagFilter == "dev, prod")
    }

    @Test(
        "accounts discover VMs carrying any filtered tag",
        arguments: [
            ("", ["prod"], true),
            ("", [], true),
            ("dev", ["dev"], true),
            ("dev", ["DEV"], true),
            ("dev, prod", ["prod", "lax"], true),
            ("dev", ["prod"], false),
            ("dev", [], false),
        ]
    )
    func discoversTaggedVMs(
        tagFilter: String,
        vmTags: [String],
        discovers: Bool
    ) {
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev",
            tagFilter: tagFilter
        )

        #expect(account.discovers(ExeVMRecord(
            vmName: "kelp-prod",
            sshDestination: "kelp-prod.exe.xyz",
            status: "running",
            tags: vmTags
        )) == discovers)
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
