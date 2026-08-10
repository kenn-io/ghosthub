import Foundation

public struct ExeAccount: Codable, Equatable, Sendable, Identifiable {
    public var configKey: String
    public var name: String
    public var sshDestination: String
    /// Comma- or space-separated exe.dev tags. Empty discovers every VM.
    public var tagFilter: String
    public var isEnabled: Bool

    public var id: String { configKey }

    private enum CodingKeys: String, CodingKey {
        case configKey, name, sshDestination, tagFilter, isEnabled
    }

    public init(
        configKey: String,
        name: String,
        sshDestination: String,
        tagFilter: String = "",
        isEnabled: Bool = true
    ) {
        self.configKey = configKey
        self.name = name
        self.sshDestination = sshDestination
        self.tagFilter = tagFilter
        self.isEnabled = isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configKey = try container.decode(String.self, forKey: .configKey)
        name = try container.decode(String.self, forKey: .name)
        sshDestination = try container.decode(
            String.self,
            forKey: .sshDestination
        )
        tagFilter = try container.decodeIfPresent(
            String.self,
            forKey: .tagFilter
        ) ?? ""
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    }

    /// Whether this account discovers `vm`, given its tag filter.
    public func discovers(_ vm: ExeVMRecord) -> Bool {
        ExeTagFilter.matches(vm.tags, filter: tagFilter)
    }
}

public enum ExeTagFilter {
    /// Splits user-entered filter text into distinct tags.
    public static func tags(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split { $0 == "," || $0.isWhitespace }
            .map(String.init)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    public static func normalized(_ text: String) -> String {
        tags(in: text).joined(separator: ", ")
    }

    /// Canonical form for asking whether two filters select the same VMs.
    /// Order, case, and duplicates do not change the answer.
    public static func key(_ text: String) -> String {
        tags(in: text).map { $0.lowercased() }.sorted().joined(separator: ",")
    }

    public static func matches(_ tags: [String], filter: String) -> Bool {
        let wanted = Set(self.tags(in: filter).map { $0.lowercased() })
        guard !wanted.isEmpty else { return true }
        return tags.contains { wanted.contains($0.lowercased()) }
    }
}

/// Everything about an account that changes which VMs it discovers.
public struct ExeAccountIdentity: Equatable, Sendable {
    public var sshDestination: String
    public var tagFilter: String

    public init(sshDestination: String, tagFilter: String = "") {
        self.sshDestination = sshDestination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        self.tagFilter = ExeTagFilter.normalized(tagFilter)
    }

    public init(_ account: ExeAccount) {
        self.init(
            sshDestination: account.sshDestination,
            tagFilter: account.tagFilter
        )
    }

    /// Identities that discover the same VMs are equal, so reordering or
    /// recasing tags neither reports a change nor discards cached inventory.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sshDestination == rhs.sshDestination
            && ExeTagFilter.key(lhs.tagFilter) == ExeTagFilter.key(rhs.tagFilter)
    }
}

public enum ExeAccountStatus: Equatable, Sendable {
    case loading
    /// `identity` is what discovery actually ran with, which a settings draft
    /// may have moved on from since.
    case loaded(totalVMs: Int, runningVMs: Int, identity: ExeAccountIdentity)
    case failed(String)
}

public struct ExeVMRecord: Decodable, Equatable, Sendable {
    public var vmName: String
    public var sshDestination: String
    public var status: String
    public var region: String?
    public var regionDisplayName: String?
    public var httpsURL: String?
    public var tags: [String]

    private enum CodingKeys: String, CodingKey {
        case vmName = "vm_name"
        case sshDestination = "ssh_dest"
        case status, region, tags
        case regionDisplayName = "region_display"
        case httpsURL = "https_url"
    }

    public init(
        vmName: String,
        sshDestination: String,
        status: String,
        region: String? = nil,
        regionDisplayName: String? = nil,
        httpsURL: String? = nil,
        tags: [String] = []
    ) {
        self.vmName = vmName
        self.sshDestination = sshDestination
        self.status = status
        self.region = region
        self.regionDisplayName = regionDisplayName
        self.httpsURL = httpsURL
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        vmName = try container.decode(String.self, forKey: .vmName)
        sshDestination = try container.decode(
            String.self,
            forKey: .sshDestination
        )
        status = try container.decode(String.self, forKey: .status)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        regionDisplayName = try container.decodeIfPresent(
            String.self,
            forKey: .regionDisplayName
        )
        httpsURL = try container.decodeIfPresent(
            String.self,
            forKey: .httpsURL
        )
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
            ?? []
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
                tagFilter: ExeTagFilter.normalized(account.tagFilter),
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
                tagFilter: ExeTagFilter.normalized(draft.tagFilter),
                isEnabled: draft.isEnabled
            ))
        }
        return reconciled
    }
}
