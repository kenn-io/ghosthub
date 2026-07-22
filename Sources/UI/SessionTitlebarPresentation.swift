import Foundation
import GhosthubWorkspace

public struct SessionTitlebarPresentation: Equatable, Sendable {
    public let sessionName: String
    public let hostname: String
    public let icon: WorkspaceSidebarRowIcon

    public init(
        sessionName: String,
        hostname: String,
        icon: WorkspaceSidebarRowIcon
    ) {
        self.sessionName = sessionName
        self.hostname = hostname
        self.icon = icon
    }

    public var title: String {
        "\(sessionName) · \(hostname)"
    }

    public static func resolve(
        activeSession: WorkspaceTmuxSessionSelection?,
        in snapshot: WorkspaceSnapshot
    ) -> SessionTitlebarPresentation? {
        guard let activeSession,
              let host = snapshot.host(id: activeSession.hostID)
        else { return nil }

        let icon: WorkspaceSidebarRowIcon
        if let worktreeID = activeSession.worktreeID {
            if let worktree = snapshot.worktree(id: worktreeID) {
                icon = worktree.isPrimary ? .primaryWorktree : .worktree
            } else {
                icon = .worktree
            }
        } else {
            icon = .tmuxSession
        }

        return SessionTitlebarPresentation(
            sessionName: activeSession.name,
            hostname: hostname(for: host),
            icon: icon
        )
    }

    private static func hostname(for host: HostSummary) -> String {
        if host.kind == .selfHost {
            return nonempty(host.name) ?? "localhost"
        }
        if let remoteHostname = nonempty(host.remoteHostname) {
            return remoteHostname
        }
        if let destination = nonempty(host.sshDestination) {
            return destinationHostname(destination)
        }
        return nonempty(host.name) ?? "remote host"
    }

    private static func destinationHostname(_ destination: String) -> String {
        let hostAndPort = destination.split(
            separator: "@",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).last.map(String.init) ?? destination

        if hostAndPort.hasPrefix("["),
           let closingBracket = hostAndPort.firstIndex(of: "]") {
            let start = hostAndPort.index(after: hostAndPort.startIndex)
            return String(hostAndPort[start..<closingBracket])
        }

        if hostAndPort.filter({ $0 == ":" }).count == 1,
           let colon = hostAndPort.firstIndex(of: ":") {
            return String(hostAndPort[..<colon])
        }
        return hostAndPort
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }
}
