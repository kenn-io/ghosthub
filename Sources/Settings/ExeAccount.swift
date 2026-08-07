import Foundation

public struct ExeAccount: Codable, Equatable, Sendable, Identifiable {
    public var configKey: String
    public var name: String
    public var sshDestination: String
    public var isEnabled: Bool

    public var id: String { configKey }

    public init(
        configKey: String,
        name: String,
        sshDestination: String,
        isEnabled: Bool = true
    ) {
        self.configKey = configKey
        self.name = name
        self.sshDestination = sshDestination
        self.isEnabled = isEnabled
    }
}

public enum ExeAccountStatus: Equatable, Sendable {
    case loading
    case loaded(totalVMs: Int, runningVMs: Int)
    case failed(String)
}

public struct ExeVMRecord: Decodable, Equatable, Sendable {
    public var vmName: String
    public var sshDestination: String
    public var status: String
    public var region: String?
    public var regionDisplayName: String?
    public var httpsURL: String?

    private enum CodingKeys: String, CodingKey {
        case vmName = "vm_name"
        case sshDestination = "ssh_dest"
        case status, region
        case regionDisplayName = "region_display"
        case httpsURL = "https_url"
    }

    public init(
        vmName: String,
        sshDestination: String,
        status: String,
        region: String? = nil,
        regionDisplayName: String? = nil,
        httpsURL: String? = nil
    ) {
        self.vmName = vmName
        self.sshDestination = sshDestination
        self.status = status
        self.region = region
        self.regionDisplayName = regionDisplayName
        self.httpsURL = httpsURL
    }

    public var isRunning: Bool {
        status.caseInsensitiveCompare("running") == .orderedSame
    }
}

public enum ExeAccountConnectionProbeResult: Equatable, Sendable {
    case connected([ExeVMRecord])
    case authenticationRequired
    case failed(String)
}

public enum ExeAccountSanitizer {
    public static func storedAccounts(
        _ accounts: [ExeAccount]
    ) -> [ExeAccount] {
        var seenKeys = Set<String>()

        return accounts.compactMap { account in
            let configKey = account.configKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let name = account.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let destination = account.sshDestination.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !configKey.isEmpty,
                  !name.isEmpty,
                  !destination.isEmpty,
                  !seenKeys.contains(configKey)
            else { return nil }
            seenKeys.insert(configKey)
            return ExeAccount(
                configKey: configKey,
                name: name,
                sshDestination: destination,
                isEnabled: account.isEnabled
            )
        }
    }

    public static func discoverableAccounts(
        _ accounts: [ExeAccount]
    ) -> [ExeAccount] {
        let stored = storedAccounts(accounts)
        let duplicates = duplicateEnabledDestinations(stored)
        return stored.filter {
            !$0.isEnabled || !duplicates.contains($0.sshDestination)
        }
    }

    public static func duplicateEnabledDestinations(
        _ accounts: [ExeAccount]
    ) -> Set<String> {
        var seen = Set<String>()
        var duplicates = Set<String>()
        for account in accounts where account.isEnabled {
            let destination = account.sshDestination.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !destination.isEmpty else { continue }
            if !seen.insert(destination).inserted {
                duplicates.insert(destination)
            }
        }
        return duplicates
    }

    public static func accountsForPersistence(
        _ drafts: [ExeAccount],
        previous: [ExeAccount]
    ) -> [ExeAccount] {
        let previousByKey = Dictionary(uniqueKeysWithValues: previous.map {
            ($0.configKey, $0)
        })
        let draftsByKey = Dictionary(grouping: drafts) {
            $0.configKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let duplicateDestinations = duplicateEnabledDestinations(drafts)
        var emittedKeys = Set<String>()
        var reconciled: [ExeAccount] = []

        for draft in drafts {
            let configKey = draft.configKey.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !configKey.isEmpty,
                  emittedKeys.insert(configKey).inserted
            else { continue }
            let previousAccount = previousByKey[configKey]
            guard draftsByKey[configKey]?.count == 1 else {
                if let previousAccount {
                    reconciled.append(previousAccount)
                }
                continue
            }

            let name = draft.name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let destination = draft.sshDestination.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            let isAmbiguous = draft.isEnabled
                && duplicateDestinations.contains(destination)
            guard !name.isEmpty, !destination.isEmpty, !isAmbiguous else {
                if var previousAccount {
                    if !draft.isEnabled {
                        previousAccount.isEnabled = false
                    }
                    reconciled.append(previousAccount)
                }
                continue
            }

            reconciled.append(ExeAccount(
                configKey: configKey,
                name: name,
                sshDestination: destination,
                isEnabled: draft.isEnabled
            ))
        }
        return reconciled
    }
}
