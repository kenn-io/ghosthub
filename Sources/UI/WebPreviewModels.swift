import Foundation
import GhosthubWorkspace

public struct WebPreviewContext: Identifiable, Hashable, Sendable {
    public let id: String
    public let worktreeID: UUID
    public let worktreeName: String

    public init(
        id: String,
        worktreeID: UUID,
        worktreeName: String
    ) {
        self.id = id
        self.worktreeID = worktreeID
        self.worktreeName = worktreeName
    }
}

public enum WebPreviewEligibility {
    public static func context(
        in snapshot: WorkspaceSnapshot,
        selection: WorkspaceSelection
    ) -> WebPreviewContext? {
        guard let worktreeID = selection.selectedWorktreeID,
              let worktree = snapshot.worktree(id: worktreeID),
              worktree.hostID == selection.selectedHostID,
              !worktree.isStale,
              let host = snapshot.host(id: worktree.hostID),
              host.kind == .selfHost
        else {
            return nil
        }

        let hostKey = WorkspaceKeyResolver.hostKey(for: host)
        let worktreeKey = WorkspaceKeyResolver.worktreeKey(for: worktree)
        return WebPreviewContext(
            id: "\(hostKey.utf8.count):\(hostKey)\(worktreeKey)",
            worktreeID: worktree.id,
            worktreeName: worktree.name
        )
    }
}

public enum WebPreviewAddressError: LocalizedError, Equatable {
    case empty
    case unsupportedScheme
    case missingHost

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter an HTTP or HTTPS address."
        case .unsupportedScheme:
            "Enter a complete address beginning with http:// or https://."
        case .missingHost:
            "Enter an address with a host name."
        }
    }
}

public enum WebPreviewAddress {
    public static func parse(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebPreviewAddressError.empty
        }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw WebPreviewAddressError.unsupportedScheme
        }
        guard let host = components.host, !host.isEmpty,
              let url = components.url
        else {
            throw WebPreviewAddressError.missingHost
        }
        return url
    }
}

public enum WebPreviewLayoutMode: Equatable, Sendable {
    case terminalOnly
    case split
    case previewOnly
}

public enum WebPreviewLayoutPolicy {
    public static let defaultPreviewWidth: CGFloat = 520
    public static let minimumPreviewWidth: CGFloat = 360
    public static let maximumPreviewWidth: CGFloat = 760
    public static let minimumTerminalWidth: CGFloat = 420
    public static let dividerWidth: CGFloat = 1

    public static func mode(
        windowWidth: CGFloat,
        sidebarWidth: CGFloat,
        isSidebarVisible: Bool,
        isPreviewAvailable: Bool,
        isPreviewRequested: Bool
    ) -> WebPreviewLayoutMode {
        guard isPreviewAvailable, isPreviewRequested else {
            return .terminalOnly
        }

        let availableWidth = windowWidth
            - (isSidebarVisible ? sidebarWidth : 0)
        let minimumSplitWidth = minimumTerminalWidth
            + dividerWidth
            + minimumPreviewWidth
        return availableWidth >= minimumSplitWidth
            ? .split
            : .previewOnly
    }

    public static func clampedPreviewWidth(
        _ proposedWidth: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        let widthAfterTerminal = max(
            0,
            availableWidth - minimumTerminalWidth - dividerWidth
        )
        let upperBound = min(maximumPreviewWidth, widthAfterTerminal)
        guard upperBound >= minimumPreviewWidth else {
            return upperBound
        }
        return min(max(proposedWidth, minimumPreviewWidth), upperBound)
    }
}
