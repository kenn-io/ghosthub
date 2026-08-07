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

public enum ExeAccountConnectionProbeResult: Equatable, Sendable {
    case connected
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
        let sanitized = discoverableAccounts(drafts)
        guard sanitized.count != drafts.count else { return sanitized }

        let draftsByKey = Dictionary(grouping: drafts) {
            $0.configKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return previous.compactMap { account in
            let matches = draftsByKey[account.configKey] ?? []
            guard !matches.isEmpty else { return nil }
            guard matches.count == 1, !matches[0].isEnabled else {
                return account
            }
            var disabled = account
            disabled.isEnabled = false
            return disabled
        }
    }
}
