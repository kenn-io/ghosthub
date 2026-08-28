import GhosthubTransport
import Combine
import Dispatch
import Foundation
import GhosthubSettings
import GhosthubTestSupport
import GhosthubTmux
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("exe.dev VM inventory")
struct ExeVMInventoryTests {
    @MainActor
    @Test("automatic refresh borrows a kwt SSH lease")
    func automaticRefreshBorrowsLease() async {
        let leasedArguments = ["-F", "/dev/null", "-S", "/tmp/kwt.sock"]
        let observedArguments = LockedValue<[String]?>(nil)
        let acquisitions = LockedValue(0)
        let client = ExeVMClient(
            runner: { _, arguments, startMarker, endMarker in
                observedArguments.store(arguments)
                return (
                    0,
                    "\(startMarker)\n{\"vms\":[]}\n\(endMarker)",
                    ""
                )
            },
            commandLease: KwtSSHCommandLease { _ in
                acquisitions.withLock { $0 += 1 }
                return KwtSSHConnection(
                    arguments: leasedArguments,
                    routeIdentity: "sha256:exe-route",
                    generation: 1
                )
            }
        )
        let store = ExeVMInventoryStore(client: client)
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )
        let loaded = Task { @MainActor in
            for await statuses in store.$statuses.values {
                if case .loaded = statuses[account.configKey] {
                    return
                }
            }
        }

        store.refresh(accounts: [account])
        await loaded.value

        #expect(acquisitions.load() == 1)
        #expect(observedArguments.load() == leasedArguments)
    }

    @Test("reviewed connection arguments are used for inventory")
    func usesReviewedConnectionArguments() throws {
        let capturedArguments = LockedValue<[String]?>(nil)
        let client = ExeVMClient { _, arguments, startMarker, endMarker in
            capturedArguments.store(arguments)
            return (
                0,
                "\(startMarker)\n{\"vms\":[]}\n\(endMarker)",
                ""
            )
        }
        let arguments = ["-S", "/tmp/reviewed.sock"]

        _ = try client.listVMs(
            for: ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev"
            ),
            sshConnectionArguments: arguments
        )

        #expect(capturedArguments.load() == arguments)
    }

    @Test("decodes framed VM inventory without login-shell output")
    func decodesVMList() throws {
        let capturedHost = LockedValue<SSHHostInfo?>(nil)
        let client = ExeVMClient { host, _, startMarker, endMarker in
            capturedHost.withLock { $0 = host }
            return (
                0,
                """
                local login-shell output
                \(startMarker)
                {"vms":[{"vm_name":"build","ssh_dest":"vm+build@exe.dev","ssh_host":"build.exe.xyz","status":"running","region":"lon","region_display":"London, UK","https_url":"https://build.exe.xyz","tags":["dev"]}]}
                \(endMarker)
                trailing output
                """,
                ""
            )
        }
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "me@exe-control:2222"
        )

        let vms = try client.listVMs(for: account)
        let vm = try #require(vms.first)

        #expect(capturedHost.load()?.user == "me")
        #expect(capturedHost.load()?.hostname == "exe-control")
        #expect(capturedHost.load()?.port == 2222)
        #expect(vm.vmName == "build")
        #expect(vm.sshDestination == "vm+build@exe.dev")
        #expect(vm.regionDisplayName == "London, UK")
        #expect(vm.tags == ["dev"])
        #expect(vm.isRunning)
    }

    @Test("reports command diagnostics instead of parsing failed output")
    func reportsCommandFailure() {
        let client = ExeVMClient { _, _, _, _ in
            (255, "", "Permission denied (publickey).")
        }

        #expect(throws: ExeVMInventoryError.commandFailed(
            destination: "exe.dev",
            status: 255,
            message: "Permission denied (publickey)."
        )) {
            try client.listVMs(for: ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev"
            ))
        }
    }

    @Test("authentication failures request supervised SSH entry")
    func classifiesAuthenticationFailure() async {
        let client = ExeVMClient { _, _, _, _ in
            (255, "", "Permission denied (publickey,password).")
        }

        #expect(await client.connectionProbe(for: ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )) == .authenticationRequired)
    }

    @Test("a reviewed probe invalidates a dead pooled connection")
    func reviewedProbeInvalidatesDeadConnection() async {
        let invalidations = LockedValue(0)
        let client = ExeVMClient { _, _, _, _ in
            (
                255,
                "",
                "Control socket connect(/tmp/dead.sock): No such file or directory"
            )
        }
        let connection = KwtSSHConnection(
            arguments: ["-S", "/tmp/dead.sock"],
            routeIdentity: "reviewed-route",
            generation: 1,
            invalidate: { invalidations.withLock { $0 += 1 } }
        )

        let result = await client.connectionProbe(
            for: ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "exe.dev"
            ),
            connection: connection
        )

        guard case .failed = result else {
            Issue.record("expected a failed connection probe")
            return
        }
        #expect(invalidations.load() == 1)
    }

    @MainActor
    @Test("changing account destination invalidates cached hosts")
    func changingAccountDestinationInvalidatesCachedHosts() async {
        let client = ExeVMClient { host, _, startMarker, endMarker in
            guard host.hostname == "old.exe.dev" else {
                return (255, "", "Connection failed")
            }
            return (
                0,
                """
                \(startMarker)
                {"vms":[{"vm_name":"build","ssh_dest":"vm+build@exe.dev","status":"running"}]}
                \(endMarker)
                """,
                ""
            )
        }
        let store = ExeVMInventoryStore(client: client)
        let initialRefresh = Task { @MainActor in
            for await statuses in store.$statuses.values {
                if statuses["personal"] == .loaded(
                    totalVMs: 1,
                    runningVMs: 1,
                    identity: ExeAccountIdentity(
                        sshDestination: "old.exe.dev"
                    )
                ) {
                    return
                }
            }
        }
        store.refresh(accounts: [ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "old.exe.dev"
        )])
        await initialRefresh.value
        #expect(store.hosts.count == 1)

        let failedRefresh = Task { @MainActor in
            for await statuses in store.$statuses.values {
                guard let status = statuses["personal"] else { continue }
                if case .failed = status {
                    return
                }
            }
        }
        store.refresh(accounts: [ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "new.exe.dev"
        )])
        await failedRefresh.value

        #expect(store.hosts.isEmpty)
    }

    @MainActor
    @Test("refresh cancellation and invalidation stay scoped")
    func refreshLifecycleIsScopedToExactOperation() async throws {
        let client = ExeVMClient { host, _, startMarker, endMarker in
            let vmName = host.hostname == "old.exe.dev" ? "old" : "new"
            return (
                0,
                """
                \(startMarker)
                {"vms":[{"vm_name":"\(vmName)","ssh_dest":"vm+\(
                    vmName
                )@exe.dev","status":"running"}]}
                \(endMarker)
                """,
                ""
            )
        }
        let store = ExeVMInventoryStore(client: client)
        let oldRefresh = Task { @MainActor in
            for await statuses in store.$statuses.values {
                if statuses["personal"] == .loaded(
                    totalVMs: 1,
                    runningVMs: 1,
                    identity: ExeAccountIdentity(
                        sshDestination: "old.exe.dev"
                    )
                ) {
                    return
                }
            }
        }
        let oldRefreshID = store.refresh(accounts: [ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "old.exe.dev"
        )])
        await oldRefresh.value

        let newRefresh = Task { @MainActor in
            for await hosts in store.$hosts.values {
                if hosts.first?.sshHost.sshDestination
                    == "vm+new@exe.dev" {
                    return
                }
            }
        }
        let newRefreshID = store.refresh(accounts: [ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "new.exe.dev"
        )])
        await newRefresh.value

        store.cancelRefresh(
            oldRefreshID,
            retaining: [ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "new.exe.dev"
            )]
        )
        let current = try #require(store.hosts.first)
        #expect(current.sshHost.sshDestination == "vm+new@exe.dev")

        store.cancelRefresh(
            newRefreshID,
            retaining: [ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "new.exe.dev"
            )]
        )
        #expect(store.hosts.count == 1)
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "new.exe.dev"
            )
        ))

        store.invalidateRefresh(newRefreshID, currentAccounts: [])
        #expect(store.hosts.count == 1)
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "new.exe.dev"
            )
        ))
    }

    @MainActor
    @Test("draft invalidation restores persisted inventory immediately")
    func draftInvalidationRestoresPersistedInventoryImmediately() async throws {
        let client = ExeVMClient { host, _, startMarker, endMarker in
            let vmName = host.hostname.components(separatedBy: ".").first!
            return (
                0,
                """
                \(startMarker)
                {"vms":[{"vm_name":"\(vmName)","ssh_dest":"vm+\(
                    vmName
                )@exe.dev","status":"running"}]}
                \(endMarker)
                """,
                ""
            )
        }
        let store = ExeVMInventoryStore(client: client)
        let persisted = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "old.exe.dev"
        )
        var loaded = Task { @MainActor in
            for await hosts in store.$hosts.values
                where hosts.first?.sshHost.sshDestination
                == "vm+old@exe.dev" {
                return
            }
        }
        store.refresh(accounts: [persisted])
        await loaded.value

        let edited = ExeAccount(
            configKey: "personal",
            name: "Edited",
            sshDestination: "new.exe.dev"
        )
        loaded = Task { @MainActor in
            for await hosts in store.$hosts.values
                where hosts.first?.sshHost.sshDestination
                == "vm+new@exe.dev" {
                return
            }
        }
        let editedRefreshID = store.refresh(
            accounts: [edited],
            persistedAccounts: [persisted]
        )
        await loaded.value
        store.invalidateRefresh(
            editedRefreshID,
            currentAccounts: [persisted]
        )

        let restored = try #require(store.hosts.first)
        #expect(restored.sshHost.sshDestination == "vm+old@exe.dev")
        #expect(restored.metadata.accountName == "Personal")
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "old.exe.dev"
            )
        ))

        let movedAgain = ExeAccount(
            configKey: "personal",
            name: "Moved again",
            sshDestination: "newer.exe.dev"
        )
        loaded = Task { @MainActor in
            for await hosts in store.$hosts.values
                where hosts.first?.sshHost.sshDestination
                == "vm+newer@exe.dev" {
                return
            }
        }
        let movedAgainRefreshID = store.refresh(
            accounts: [movedAgain],
            persistedAccounts: [persisted]
        )
        await loaded.value
        store.invalidateRefresh(
            movedAgainRefreshID,
            currentAccounts: [persisted]
        )
        #expect(store.hosts.first?.sshHost.sshDestination == "vm+old@exe.dev")
        store.cancelRefresh(movedAgainRefreshID, retaining: [persisted])

        let added = ExeAccount(
            configKey: "work",
            name: "Work",
            sshDestination: "work.exe.dev"
        )
        let addedLoaded = Task { @MainActor in
            for await hosts in store.$hosts.values where hosts.count == 2 {
                return
            }
        }
        let addedRefreshID = store.refresh(
            accounts: [persisted, added],
            persistedAccounts: [persisted]
        )
        await addedLoaded.value
        store.invalidateRefresh(
            addedRefreshID,
            currentAccounts: [persisted]
        )

        #expect(store.hosts.map(\.metadata.accountConfigKey) == ["personal"])
        #expect(store.statuses["work"] == nil)
        store.cancelRefresh(addedRefreshID, retaining: [persisted])
    }

    @MainActor
    @Test("prefetched connection inventory is published without another query")
    func prefetchedInventoryAvoidsAnotherQuery() throws {
        let queryCount = LockedValue(0)
        let store = ExeVMInventoryStore(client: ExeVMClient { _, _, _, _ in
            queryCount.withLock { $0 += 1 }
            return (255, "", "Unexpected query")
        })
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )

        store.refresh(
            accounts: [account],
            persistedAccounts: [],
            prefetchedVMs: [
                account.configKey: [ExeVMRecord(
                    vmName: "build",
                    sshDestination: "vm+build@exe.dev",
                    status: "running"
                )],
            ]
        )

        #expect(queryCount.load() == 0)
        #expect(try #require(store.hosts.first).sshHost.sshDestination
            == "vm+build@exe.dev")
        #expect(store.statuses[account.configKey] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "exe.dev"
            )
        ))
    }

    @MainActor
    @Test("cancelling a refresh preserves completed account state")
    func cancellationPreservesCompletedAccountState() async {
        let (workStarted, workStartedContinuation) =
            AsyncStream<Void>.makeStream()
        let releaseWork = DispatchSemaphore(value: 0)
        defer { releaseWork.signal() }
        let client = ExeVMClient { host, _, startMarker, endMarker in
            if host.hostname == "work.exe.dev" {
                workStartedContinuation.yield()
                releaseWork.wait()
            }
            let vmName = host.hostname.components(separatedBy: ".").first!
            return (
                0,
                """
                \(startMarker)
                {"vms":[{"vm_name":"\(vmName)","ssh_dest":"vm+\(
                    vmName
                )@exe.dev","status":"running"}]}
                \(endMarker)
                """,
                ""
            )
        }
        let store = ExeVMInventoryStore(client: client)
        let cancellations = LockedValue(0)
        var refreshID: UUID?
        let cancellable = store.$statuses.sink { statuses in
            guard cancellations.load() == 0,
                  statuses["personal"] == .loaded(
                      totalVMs: 1,
                      runningVMs: 1,
                      identity: ExeAccountIdentity(
                          sshDestination: "personal.exe.dev"
                      )
                  ),
                  let refreshID
            else { return }
            cancellations.withLock { $0 += 1 }
            store.cancelRefresh(
                refreshID,
                retaining: [
                    ExeAccount(
                        configKey: "personal",
                        name: "Personal",
                        sshDestination: "personal.exe.dev"
                    ),
                    ExeAccount(
                        configKey: "work",
                        name: "Work",
                        sshDestination: "work.exe.dev"
                    ),
                ]
            )
        }
        refreshID = store.refresh(accounts: [
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "personal.exe.dev"
            ),
            ExeAccount(
                configKey: "work",
                name: "Work",
                sshDestination: "work.exe.dev"
            ),
        ])
        for await _ in workStarted.prefix(1) {}
        await waitUntilMainActor {
            cancellations.load() == 1
        }

        withExtendedLifetime(cancellable) {
            #expect(
                store.hosts.map(\.metadata.accountConfigKey) == ["personal"]
            )
            #expect(store.statuses["personal"] == .loaded(
                totalVMs: 1,
                runningVMs: 1,
                identity: ExeAccountIdentity(
                    sshDestination: "personal.exe.dev"
                )
            ))
            #expect(store.statuses["work"] == nil)
        }
    }

    @MainActor
    @Test("renamed cached hosts survive a failed refresh")
    func renamedCachedHostsSurviveFailedRefresh() async {
        let attempts = LockedValue(0)
        let client = ExeVMClient { _, _, startMarker, endMarker in
            var attempt = 0
            attempts.withLock {
                $0 += 1
                attempt = $0
            }
            guard attempt == 1 else {
                return (255, "", "Connection failed")
            }
            return (
                0,
                """
                \(startMarker)
                {"vms":[{"vm_name":"build","ssh_dest":"vm+build@exe.dev","status":"running"}]}
                \(endMarker)
                """,
                ""
            )
        }
        let store = ExeVMInventoryStore(client: client)
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )
        let loaded = Task { @MainActor in
            for await statuses in store.$statuses.values {
                guard case .loaded = statuses["personal"] else { continue }
                return
            }
        }
        store.refresh(accounts: [account])
        await loaded.value

        let failed = Task { @MainActor in
            for await statuses in store.$statuses.values {
                guard case .failed = statuses["personal"] else { continue }
                return
            }
        }
        store.refresh(accounts: [ExeAccount(
            configKey: "personal",
            name: "Renamed",
            sshDestination: "exe.dev"
        )])
        await failed.value

        #expect(store.hosts.first?.metadata.accountName == "Renamed")
    }

    @MainActor
    @Test("account edits preserve unchanged inventory")
    func accountEditsPreserveUnchangedInventory() async {
        let client = ExeVMClient { host, _, startMarker, endMarker in
            let vmName = host.hostname.components(separatedBy: ".").first!
            return (
                0,
                """
                \(startMarker)
                {"vms":[{"vm_name":"\(vmName)","ssh_dest":"vm+\(
                    vmName
                )@exe.dev","status":"running"}]}
                \(endMarker)
                """,
                ""
            )
        }
        let store = ExeVMInventoryStore(client: client)
        let accounts = [
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "personal.exe.dev"
            ),
            ExeAccount(
                configKey: "work",
                name: "Work",
                sshDestination: "work.exe.dev"
            ),
        ]
        let loaded = Task { @MainActor in
            for await hosts in store.$hosts.values where hosts.count == 2 {
                return
            }
        }
        let refreshID = store.refresh(accounts: accounts)
        await loaded.value

        store.invalidateRefresh(
            refreshID,
            currentAccounts: [
                accounts[0],
                ExeAccount(
                    configKey: "work",
                    name: "Renamed Work",
                    sshDestination: "work.exe.dev"
                ),
            ]
        )
        #expect(store.hosts.first(where: {
            $0.metadata.accountConfigKey == "work"
        })?.metadata.accountName == "Renamed Work")

        store.invalidateRefresh(
            refreshID,
            currentAccounts: [
                ExeAccount(
                    configKey: "personal",
                    name: "Personal",
                    sshDestination: "moved.exe.dev"
                ),
                ExeAccount(
                    configKey: "work",
                    name: "   ",
                    sshDestination: "work.exe.dev"
                ),
            ]
        )

        #expect(store.hosts.count == 2)
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "personal.exe.dev"
            )
        ))
        #expect(store.statuses["work"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "work.exe.dev"
            )
        ))

        store.invalidateRefresh(
            refreshID,
            currentAccounts: [
                accounts[0],
                ExeAccount(
                    configKey: "work",
                    name: "Renamed Work",
                    sshDestination: "personal.exe.dev"
                ),
            ]
        )
        #expect(store.hosts.count == 2)

        store.invalidateRefresh(
            refreshID,
            currentAccounts: [
                ExeAccount(
                    configKey: "personal",
                    name: "Personal",
                    sshDestination: "moved.exe.dev"
                ),
                ExeAccount(
                    configKey: "work",
                    name: "Renamed Work",
                    sshDestination: "work.exe.dev"
                ),
            ]
        )
        #expect(store.hosts.count == 2)
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "personal.exe.dev"
            )
        ))

        store.invalidateRefresh(
            refreshID,
            currentAccounts: [
                accounts[0],
                ExeAccount(
                    configKey: "work",
                    name: "Renamed Work",
                    sshDestination: "work.exe.dev"
                ),
            ]
        )
        #expect(store.hosts.count == 2)
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "personal.exe.dev"
            )
        ))

        store.invalidateRefresh(
            refreshID,
            currentAccounts: [
                accounts[0],
                ExeAccount(
                    configKey: "work",
                    name: "",
                    sshDestination: "",
                    isEnabled: false
                ),
            ]
        )
        #expect(store.hosts.count == 2)
        #expect(store.statuses["work"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "work.exe.dev"
            )
        ))

        store.invalidateRefresh(
            refreshID,
            currentAccounts: [
                accounts[0],
                ExeAccount(
                    configKey: "work",
                    name: "Renamed Work",
                    sshDestination: "work.exe.dev"
                ),
            ]
        )
        #expect(store.hosts.count == 2)
        #expect(store.statuses["work"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "work.exe.dev"
            )
        ))

        store.invalidateRefresh(refreshID, currentAccounts: [])
        #expect(store.hosts.count == 2)

        store.refresh(accounts: [])
        #expect(store.hosts.isEmpty)
    }

    @MainActor
    @Test("in-flight edits preserve retained account results")
    func inFlightEditsPreserveRetainedResults() async {
        let (workStarted, workStartedContinuation) =
            AsyncStream<Void>.makeStream()
        let releasePersonal = DispatchSemaphore(value: 0)
        let releaseWork = DispatchSemaphore(value: 0)
        let client = ExeVMClient { host, _, startMarker, endMarker in
            if host.hostname == "personal.exe.dev" {
                releasePersonal.wait()
            }
            if host.hostname == "work.exe.dev" {
                workStartedContinuation.yield()
                releaseWork.wait()
            }
            let vmName = host.hostname.components(separatedBy: ".").first!
            return (
                0,
                """
                \(startMarker)
                {"vms":[{"vm_name":"\(vmName)","ssh_dest":"vm+\(
                    vmName
                )@exe.dev","status":"running"}]}
                \(endMarker)
                """,
                ""
            )
        }
        let store = ExeVMInventoryStore(client: client)
        let accounts = [
            ExeAccount(
                configKey: "personal",
                name: "Personal",
                sshDestination: "personal.exe.dev"
            ),
            ExeAccount(
                configKey: "work",
                name: "Work",
                sshDestination: "work.exe.dev"
            ),
        ]
        let personalPublished = Task { @MainActor in
            for await hosts in store.$hosts.values {
                if hosts.contains(where: {
                    $0.metadata.accountConfigKey == "personal"
                }) {
                    return
                }
            }
        }
        let published = Task { @MainActor in
            for await hosts in store.$hosts.values {
                if hosts.contains(where: {
                    $0.metadata.accountConfigKey == "work"
                }) {
                    return
                }
            }
        }
        let refreshID = store.refresh(accounts: accounts)
        for await _ in workStarted.prefix(1) {}
        releasePersonal.signal()
        await personalPublished.value

        store.invalidateRefresh(
            refreshID,
            currentAccounts: [
                ExeAccount(
                    configKey: "personal",
                    name: "Personal",
                    sshDestination: "moved.exe.dev"
                ),
                ExeAccount(
                    configKey: "work",
                    name: "",
                    sshDestination: "work.exe.dev"
                ),
            ]
        )
        releaseWork.signal()
        await published.value

        #expect(store.hosts.count == 2)
        #expect(store.hosts.first(where: {
            $0.metadata.accountConfigKey == "work"
        })?.metadata.accountName == "Work")
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "personal.exe.dev"
            )
        ))
        #expect(store.statuses["work"] == .loaded(
            totalVMs: 1,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "work.exe.dev"
            )
        ))
    }

    @MainActor
    @Test("tag filters scope discovered VMs and reported counts")
    func tagFilterScopesDiscoveredVMs() {
        let store = ExeVMInventoryStore(client: ExeVMClient { _, _, _, _ in
            (255, "", "Unexpected query")
        })
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev",
            tagFilter: "Dev"
        )

        store.refresh(
            accounts: [account],
            persistedAccounts: [account],
            prefetchedVMs: [account.configKey: [
                ExeVMRecord(
                    vmName: "kelp-dev",
                    sshDestination: "kelp-dev.exe.xyz",
                    status: "running",
                    tags: ["dev"]
                ),
                ExeVMRecord(
                    vmName: "kelp-dev-stopped",
                    sshDestination: "kelp-dev-stopped.exe.xyz",
                    status: "stopped",
                    tags: ["dev"]
                ),
                ExeVMRecord(
                    vmName: "kelp-prod",
                    sshDestination: "kelp-prod.exe.xyz",
                    status: "running",
                    tags: ["prod"]
                ),
                ExeVMRecord(
                    vmName: "scratchme",
                    sshDestination: "scratchme.exe.xyz",
                    status: "running"
                ),
            ]]
        )

        #expect(store.hosts.map(\.sshHost.name) == ["kelp-dev"])
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 2,
            runningVMs: 1,
            identity: ExeAccountIdentity(
                sshDestination: "exe.dev", tagFilter: "Dev"
            )
        ))
    }

    @MainActor
    @Test("reordering tags keeps cached hosts and the discovered filter")
    func reorderingTagsKeepsCachedHosts() {
        let store = ExeVMInventoryStore(client: ExeVMClient { _, _, _, _ in
            (255, "", "Unexpected query")
        })
        let account = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev",
            tagFilter: "dev, prod"
        )
        let reordered = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev",
            tagFilter: "PROD,dev"
        )
        store.refresh(
            accounts: [account],
            persistedAccounts: [account],
            prefetchedVMs: [account.configKey: [ExeVMRecord(
                vmName: "kelp-dev",
                sshDestination: "kelp-dev.exe.xyz",
                status: "running",
                tags: ["dev"]
            )]]
        )
        let refreshID = store.refresh(
            accounts: [reordered],
            persistedAccounts: [account]
        )
        store.invalidateRefresh(refreshID, currentAccounts: [reordered])

        // Cache survives: an equivalent filter is not a new identity. The
        // status is left alone here because that second refresh is in flight.
        #expect(store.hosts.map(\.sshHost.name) == ["kelp-dev"])
        store.cancelRefresh(refreshID, retaining: [reordered])
        #expect(store.hosts.map(\.sshHost.name) == ["kelp-dev"])
    }

    @MainActor
    @Test("changing only the tag filter invalidates cached hosts")
    func changingTagFilterInvalidatesCachedHosts() async {
        let client = ExeVMClient { _, _, startMarker, endMarker in
            (
                0,
                """
                \(startMarker)
                {"vms":[{"vm_name":"kelp-dev","ssh_dest":"kelp-dev.exe.xyz","status":"running","tags":["dev"]},{"vm_name":"kelp-prod","ssh_dest":"kelp-prod.exe.xyz","status":"running","tags":["prod"]}]}
                \(endMarker)
                """,
                ""
            )
        }
        let store = ExeVMInventoryStore(client: client)
        let devAccount = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev",
            tagFilter: "dev"
        )
        let prodAccount = ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev",
            tagFilter: "prod"
        )
        var loaded = Task { @MainActor in
            for await hosts in store.$hosts.values
                where hosts.first?.sshHost.name == "kelp-dev" {
                return
            }
        }
        store.refresh(accounts: [devAccount])
        await loaded.value

        loaded = Task { @MainActor in
            for await hosts in store.$hosts.values
                where hosts.first?.sshHost.name == "kelp-prod" {
                return
            }
        }
        let prodRefreshID = store.refresh(
            accounts: [prodAccount],
            persistedAccounts: [devAccount]
        )
        await loaded.value

        store.invalidateRefresh(
            prodRefreshID,
            currentAccounts: [devAccount]
        )
        #expect(store.hosts.map(\.sshHost.name) == ["kelp-dev"])

        store.cancelRefresh(prodRefreshID, retaining: [devAccount])
        #expect(store.hosts.map(\.sshHost.name) == ["kelp-dev"])
    }
}
