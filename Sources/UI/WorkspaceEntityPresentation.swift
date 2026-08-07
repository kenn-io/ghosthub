import GhosthubWorkspace

extension HostSummary {
    var sidebarTitle: String {
        name.isEmpty ? "Untitled" : name
    }

    var sidebarSubtitle: String? {
        guard kind == .remote else {
            return nil
        }
        if let exeVM {
            let location = exeVM.regionDisplayName ?? exeVM.region
            return ["exe.dev", exeVM.accountName, location]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        return sshDestination ?? remoteHostname
    }

    var commandPaletteSubtitle: String {
        switch kind {
        case .selfHost:
            return "Local host · \(platform.displayName)"
        case .remote:
            return "\(remoteIdentityText) · \(platform.displayName)"
        }
    }

    var searchKeywords: [String] {
        let baseKeywords: [String] = [
            name,
            kind.rawValue,
            platform.rawValue,
            platform.displayName,
            preferredTransport.rawValue,
            preferredTransport.displayName,
            connectionState.rawValue,
            connectionState.label,
            sshDestination,
            remoteHostname,
            version,
            exeVM?.accountName,
            exeVM?.vmName,
            exeVM?.region,
            exeVM?.regionDisplayName,
            exeVM?.httpsURL,
        ].compactMap { value in
            guard let value else {
                return nil
            }
            return value.lowercased()
        }
        let diagnosticKeywords = remoteDiagnostics.flatMap { diagnostic in
            [
                diagnostic.summary.lowercased(),
                diagnostic.recoverySuggestion.lowercased(),
            ]
        }
        return baseKeywords + diagnosticKeywords
    }

    private var remoteIdentityText: String {
        sshDestination ?? remoteHostname ?? name
    }
}

extension ProjectSummary {
    var sidebarTitle: String {
        name.isEmpty ? "Untitled" : name
    }

    var sidebarSubtitle: String {
        platformRepositoryFullName ?? rootPath
    }
}

extension WorktreeSummary {
    var sidebarTitle: String {
        name.isEmpty ? "Untitled" : name
    }

    var sidebarSubtitle: String {
        var parts: [String] = []
        if !branch.isEmpty {
            parts.append(branch)
        }
        if let linkedPullRequestNumber {
            parts.append("#\(linkedPullRequestNumber)")
        } else if let issueNumber = linkedIssueNumbers.first {
            parts.append("#\(issueNumber)")
        }
        return parts.joined(separator: " · ")
    }
}

extension WorkspaceKnownAgent {
    var displayName: String {
        switch self {
        case .claude:
            return "Claude"
        case .codex:
            return "Codex"
        case .opencode:
            return "OpenCode"
        case .gemini:
            return "Gemini"
        case .copilot:
            return "Copilot"
        }
    }
}

extension HostPlatform {
    var displayName: String {
        switch self {
        case .macOS:
            return "macOS"
        case .linux:
            return "Linux"
        case .windows:
            return "Windows"
        }
    }
}

extension HostTransport {
    var displayName: String {
        switch self {
        case .local:
            return "Local"
        case .ssh:
            return "SSH"
        case .mosh:
            return "Mosh"
        case .http:
            return "HTTP"
        }
    }
}

extension HostConnectionState {
    var label: String {
        switch self {
        case .local:
            return "Local"
        case .connecting:
            return "Connecting"
        case .reconnecting:
            return "Reconnecting"
        case .online:
            return "Online"
        case .degraded:
            return "Degraded"
        case .offline:
            return "Offline"
        }
    }
}
