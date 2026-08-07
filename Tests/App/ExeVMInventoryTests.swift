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
    @Test("decodes framed VM inventory without login-shell output")
    func decodesVMList() throws {
        let capturedHost = LockedValue<SSHHostInfo?>(nil)
        let client = ExeVMClient { host, startMarker, endMarker in
            capturedHost.withLock { $0 = host }
            return (
                0,
                """
                local login-shell output
                \(startMarker)
                {"vms":[{"vm_name":"build","ssh_dest":"vm+build@exe.dev","ssh_host":"build.exe.xyz","status":"running","region":"lon","region_display":"London, UK","https_url":"https://build.exe.xyz"}]}
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
        #expect(vm.isRunning)
    }

    @Test("reports command diagnostics instead of parsing failed output")
    func reportsCommandFailure() {
        let client = ExeVMClient { _, _, _ in
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
    func classifiesAuthenticationFailure() {
        let client = ExeVMClient { _, _, _ in
            (255, "", "Permission denied (publickey,password).")
        }

        #expect(client.connectionProbe(for: ExeAccount(
            configKey: "personal",
            name: "Personal",
            sshDestination: "exe.dev"
        )) == .authenticationRequired)
    }

    @MainActor
    @Test("changing account destination invalidates cached hosts")
    func changingAccountDestinationInvalidatesCachedHosts() async {
        let client = ExeVMClient { host, startMarker, endMarker in
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
                    runningVMs: 1
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
        let client = ExeVMClient { host, startMarker, endMarker in
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
                    runningVMs: 1
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
            runningVMs: 1
        ))

        store.invalidateRefresh(newRefreshID, currentAccounts: [])
        #expect(store.hosts.count == 1)
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1
        ))
    }

    @MainActor
    @Test("ending a draft refresh restores persisted inventory")
    func endingDraftRefreshRestoresPersistedInventory() async throws {
        let client = ExeVMClient { host, startMarker, endMarker in
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
        let persistedRefreshID = store.refresh(accounts: [persisted])
        await loaded.value
        store.cancelRefresh(persistedRefreshID, retaining: [persisted])

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
        let editedRefreshID = store.refresh(accounts: [edited])
        await loaded.value
        store.invalidateRefresh(
            editedRefreshID,
            currentAccounts: [persisted]
        )
        store.cancelRefresh(editedRefreshID, retaining: [persisted])

        let restored = try #require(store.hosts.first)
        #expect(restored.sshHost.sshDestination == "vm+old@exe.dev")
        #expect(restored.metadata.accountName == "Personal")
        #expect(store.statuses["personal"] == .loaded(
            totalVMs: 1,
            runningVMs: 1
        ))

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
        let addedRefreshID = store.refresh(accounts: [persisted, added])
        await addedLoaded.value
        store.invalidateRefresh(
            addedRefreshID,
            currentAccounts: [persisted]
        )
        store.cancelRefresh(addedRefreshID, retaining: [persisted])

        #expect(store.hosts.map(\.metadata.accountConfigKey) == ["personal"])
        #expect(store.statuses["work"] == nil)
    }

    @MainActor
    @Test("cancelling a refresh preserves completed account state")
    func cancellationPreservesCompletedAccountState() async {
        let (workStarted, workStartedContinuation) =
            AsyncStream<Void>.makeStream()
        let releaseWork = DispatchSemaphore(value: 0)
        defer { releaseWork.signal() }
        let client = ExeVMClient { host, startMarker, endMarker in
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
                      runningVMs: 1
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
                runningVMs: 1
            ))
            #expect(store.statuses["work"] == nil)
        }
    }

    @MainActor
    @Test("renamed cached hosts survive a failed refresh")
    func renamedCachedHostsSurviveFailedRefresh() async {
        let attempts = LockedValue(0)
        let client = ExeVMClient { _, startMarker, endMarker in
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
        let client = ExeVMClient { host, startMarker, endMarker in
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
            runningVMs: 1
        ))
        #expect(store.statuses["work"] == .loaded(
            totalVMs: 1,
            runningVMs: 1
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
            runningVMs: 1
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
            runningVMs: 1
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
            runningVMs: 1
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
            runningVMs: 1
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
        let releaseWork = DispatchSemaphore(value: 0)
        let client = ExeVMClient { host, startMarker, endMarker in
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
            runningVMs: 1
        ))
        #expect(store.statuses["work"] == .loaded(
            totalVMs: 1,
            runningVMs: 1
        ))
    }
}
