import Foundation
import GhosthubWorkspace

public struct HostProbeSummary: Equatable, Sendable {
    public var host: HostSummary
    public var reachabilityKnown: Bool

    public init(
        host: HostSummary,
        reachabilityKnown: Bool = true
    ) {
        self.host = host
        self.reachabilityKnown = reachabilityKnown
    }

    public var name: String {
        host.name
    }

    public var hostname: String {
        host.remoteHostname ?? host.sshDestination
            ?? host.name
    }

    public var platform: HostPlatform {
        host.platform
    }

    public var connectionState: HostConnectionState {
        host.connectionState
    }

    public var dependencySummary: String {
        host.remoteCapabilities?.dependencies.settingsSummaryText
            ?? "unknown"
    }

    public var featureSummary: String {
        host.remoteCapabilities?.features.settingsSummaryText
            ?? "unknown"
    }

    public var diagnostics: [RemoteHostDiagnostic] {
        host.remoteDiagnostics
    }

    public var subtitle: String {
        switch host.kind {
        case .selfHost:
            return "Local host · \(host.platform.settingsDisplayName)"
        case .remote:
            return "\(remoteIdentityText) · \(host.platform.settingsDisplayName)"
        }
    }

    private var remoteIdentityText: String {
        host.sshDestination ?? host.remoteHostname ?? host.name
    }
}

private extension RemoteHostDependencyCapabilities {
    var settingsSummaryText: String {
        capabilitySummary(
            [
                ("git", git),
                ("gh", gh),
                ("gh auth", platformAuthenticated ?? false),
                ("tmux", tmux),
            ]
        )
    }
}

private extension RemoteHostFeatureCapabilities {
    var settingsSummaryText: String {
        capabilitySummary(
            [
                ("resource metrics", resourceMetrics),
                ("setup hook", setupHook),
                ("teardown hook", teardownHook),
                ("mosh attach", moshAttach),
            ]
        )
    }
}

private extension HostPlatform {
    var settingsDisplayName: String {
        switch self {
        case .macOS:
            return "macOS"
        case .linux:
            return "Linux"
        }
    }
}

private func capabilitySummary(
    _ items: [(String, Bool)]
) -> String {
    let enabled = items.compactMap { item, isEnabled in
        isEnabled ? item : nil
    }
    return enabled.isEmpty ? "none" : enabled.joined(separator: ", ")
}

public enum HostProbeError: Error, Equatable, Sendable {
    case message(String)

    public var displayMessage: String {
        switch self {
        case let .message(message):
            return message
        }
    }
}

public extension HostProbeSummary {
    /// Build a probe summary from a discovered host.
    static func fromHostSummary(
        _ host: HostSummary
    ) -> HostProbeSummary {
        HostProbeSummary(host: host, reachabilityKnown: true)
    }

}
