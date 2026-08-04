import Foundation
import GhosthubSettings
import GhosthubTmux

enum SSHHostTrustError: Error, Equatable, LocalizedError {
    case invalidPrompt
    case hostKeyChanged
    case hostKeyWasNotSaved
    case strictHostKeyPolicyUnavailable
    case strictHostKeyPolicyUnsupported(String)
    case unsupportedProxyRoute
    case temporaryStateUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPrompt:
            return "OpenSSH requested confirmation without providing a"
                + " recognizable host-key fingerprint."
        case .hostKeyChanged:
            return "The SSH host key changed before approval. Review the new"
                + " fingerprint and try again."
        case .hostKeyWasNotSaved:
            return "OpenSSH did not save the approved host key. Check the"
                + " configured UserKnownHostsFile and try again."
        case .strictHostKeyPolicyUnavailable:
            return "Ghosthub could not read OpenSSH's effective"
                + " StrictHostKeyChecking policy for this destination."
        case let .strictHostKeyPolicyUnsupported(policy):
            return "OpenSSH has StrictHostKeyChecking set to \(policy) for"
                + " this destination. Ghosthub will not override that policy;"
                + " use ask or accept-new to review unseen keys in Ghosthub."
        case .unsupportedProxyRoute:
            return "This SSH destination uses a proxy route Ghosthub cannot"
                + " safely review. Use one direct ProxyJump list whose hosts"
                + " do not introduce another proxy route."
        case .temporaryStateUnavailable:
            return "Ghosthub could not prepare secure temporary state for SSH"
                + " host-key confirmation."
        }
    }
}

enum SSHHostTrustRequirement: Equatable, Sendable {
    case none
    case confirmation(SSHHostKeyConfirmation)
    case authentication(SSHAuthenticationTarget)
}

struct SSHHostTrustManager: Sendable {
    typealias AskPassRunner = @Sendable (
        SSHHostInfo,
        [SSHHostInfo],
        URL,
        URL,
        URL,
        URL?
    ) -> Void
    typealias StrictHostKeyPolicyProvider = @Sendable (SSHHostInfo) -> String?
    typealias RouteProvider = @Sendable (SSHHostInfo) throws -> [SSHHostInfo]
    typealias AuthenticationProvider = @Sendable (SSHAuthenticationTarget)
        -> Bool

    private let askPassRunner: AskPassRunner
    private let strictHostKeyPolicyProvider: StrictHostKeyPolicyProvider
    private let routeProvider: RouteProvider
    private let authenticationProvider: AuthenticationProvider

    init(
        askPassRunner: @escaping AskPassRunner = Self.runAskPass,
        strictHostKeyPolicyProvider:
        @escaping StrictHostKeyPolicyProvider = {
            SSHConfigurationResolver.configuration(for: $0)?
                .strictHostKeyChecking
        },
        routeProvider: @escaping RouteProvider = { try Self.route(for: $0) },
        authenticationProvider: @escaping AuthenticationProvider = {
            SSHConnectionPool.isAuthenticated($0)
        }
    ) {
        self.askPassRunner = askPassRunner
        self.strictHostKeyPolicyProvider = strictHostKeyPolicyProvider
        self.routeProvider = routeProvider
        self.authenticationProvider = authenticationProvider
    }

    private struct ReviewTarget {
        let host: SSHHostInfo
        let precedingProxyHops: [SSHHostInfo]
        let requiresReview: Bool

        var authenticationTarget: SSHAuthenticationTarget {
            SSHAuthenticationTarget(
                host: host,
                precedingProxyHops: precedingProxyHops
            )
        }
    }

    private static func route(for host: SSHHostInfo) throws -> [SSHHostInfo] {
        try route(
            for: host,
            configurationProvider: SSHConfigurationResolver.configuration
        )
    }

    static func route(
        for host: SSHHostInfo,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider
    ) throws -> [SSHHostInfo] {
        guard let configuration = configurationProvider(host) else {
            throw SSHHostTrustError.strictHostKeyPolicyUnavailable
        }
        guard configuration.proxyCommand == nil else {
            throw SSHHostTrustError.unsupportedProxyRoute
        }
        guard let proxyJump = configuration.proxyJump else { return [host] }

        guard let proxyHops = SSHConfigurationResolver
            .effectiveProxyJumpHops(
                proxyJump,
                configurationProvider: configurationProvider
            )
        else {
            throw SSHHostTrustError.unsupportedProxyRoute
        }
        return proxyHops.map(\.host) + [host]
    }

    func pendingConfirmation(
        for host: SSHHostInfo,
        destination: String
    ) throws -> SSHHostKeyConfirmation? {
        guard case let .confirmation(confirmation) = try pendingRequirement(
            for: host,
            destination: destination
        ) else { return nil }
        return confirmation
    }

    func pendingRequirement(
        for host: SSHHostInfo,
        destination: String
    ) throws -> SSHHostTrustRequirement {
        for target in try reviewTargets(for: host) where target.requiresReview {
            if let precedingTarget = target.authenticationTarget
                .precedingTarget,
                !authenticationProvider(precedingTarget) {
                return .authentication(precedingTarget)
            }
            let confirmation = try withTemporaryState {
                state -> SSHHostKeyConfirmation? in
                askPassRunner(
                    target.host,
                    target.precedingProxyHops,
                    state.helper,
                    state.observedPrompt,
                    state.approvedPrompt,
                    nil
                )
                guard let prompt = try readPrompt(
                    at: state.observedPrompt
                ) else {
                    return nil
                }
                return try Self.confirmation(
                    destination: destination,
                    openSSHPrompt: prompt
                )
            }
            if let confirmation {
                return .confirmation(confirmation)
            }
        }
        return .none
    }

    func accept(
        _ confirmation: SSHHostKeyConfirmation,
        for host: SSHHostInfo,
        destination: String
    ) throws -> SSHHostKeyConfirmation? {
        guard case let .confirmation(next) = try acceptRequirement(
            confirmation,
            for: host,
            destination: destination
        ) else { return nil }
        return next
    }

    func acceptRequirement(
        _ confirmation: SSHHostKeyConfirmation,
        for host: SSHHostInfo,
        destination: String
    ) throws -> SSHHostTrustRequirement {
        guard confirmation.connectionDestination == destination else {
            throw SSHHostTrustError.hostKeyChanged
        }
        var approved = false
        for target in try reviewTargets(for: host)
            where target.requiresReview {
            approved = try withTemporaryState { state in
                try Data(Self.keyIdentity(for: confirmation).utf8).write(
                    to: state.expectedKeyIdentity,
                    options: .atomic
                )
                askPassRunner(
                    target.host,
                    target.precedingProxyHops,
                    state.helper,
                    state.observedPrompt,
                    state.approvedPrompt,
                    state.expectedKeyIdentity
                )
                return FileManager.default.fileExists(
                    atPath: state.approvedPrompt.path
                )
            }
            if approved {
                break
            }
        }
        guard approved else { throw SSHHostTrustError.hostKeyChanged }

        let requirement = try pendingRequirement(
            for: host,
            destination: destination
        )
        if case let .confirmation(pending) = requirement {
            if pending.algorithm == confirmation.algorithm,
               pending.fingerprint == confirmation.fingerprint,
               Self.logicalHost(pending.destination)
               == Self.logicalHost(confirmation.destination) {
                throw SSHHostTrustError.hostKeyWasNotSaved
            }
            return requirement
        }
        return requirement
    }

    private func reviewTargets(
        for host: SSHHostInfo
    ) throws -> [ReviewTarget] {
        let route = try routeProvider(host)
        guard route.last == host else {
            throw SSHHostTrustError.unsupportedProxyRoute
        }
        return try route.enumerated().map { index, target in
            guard let policy = SSHConfigurationResolver
                .normalizedHostKeyPolicy(
                    strictHostKeyPolicyProvider(target)
                ) else {
                throw SSHHostTrustError.strictHostKeyPolicyUnavailable
            }
            let requiresReview: Bool
            switch policy {
            case "ask", "accept-new":
                requiresReview = true
            case "yes", "no", "off":
                requiresReview = false
            default:
                throw SSHHostTrustError
                    .strictHostKeyPolicyUnsupported(policy)
            }
            return ReviewTarget(
                host: target,
                precedingProxyHops: Array(route.prefix(index)),
                requiresReview: requiresReview
            )
        }
    }

    private static func keyIdentity(
        for confirmation: SSHHostKeyConfirmation
    ) -> String {
        "\(logicalHost(confirmation.destination))\n"
            + "\(confirmation.algorithm)\n"
            + "\(confirmation.fingerprint)\n"
    }

    private static func logicalHost(_ promptDestination: String) -> String {
        promptDestination.components(separatedBy: " (").first
            ?? promptDestination
    }

    static func confirmation(
        destination: String,
        openSSHPrompt: String
    ) throws -> SSHHostKeyConfirmation {
        let hostPrefix = "The authenticity of host '"
        let hostSuffix = "' can't be established."
        guard let hostLine = openSSHPrompt.components(separatedBy: .newlines)
            .first(where: {
                $0.contains(hostPrefix) && $0.contains(hostSuffix)
            }),
            let hostStart = hostLine.range(of: hostPrefix)?.upperBound,
            let hostEnd = hostLine.range(
                of: hostSuffix,
                range: hostStart ..< hostLine.endIndex
            )?.lowerBound,
            hostStart < hostEnd
        else {
            throw SSHHostTrustError.invalidPrompt
        }
        let promptDestination = String(hostLine[hostStart ..< hostEnd])
        let fingerprintMarkers = [
            " key fingerprint is: ",
            " key fingerprint is ",
        ]
        guard let match = openSSHPrompt.components(separatedBy: .newlines)
            .compactMap({ line -> (String, Range<String.Index>)? in
                guard let markerRange = fingerprintMarkers.compactMap({
                    line.range(of: $0)
                }).first else {
                    return nil
                }
                return (line, markerRange)
            }).first
        else {
            throw SSHHostTrustError.invalidPrompt
        }
        let algorithm = match.0[..<match.1.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fingerprint = match.0[match.1.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !algorithm.isEmpty, !fingerprint.isEmpty else {
            throw SSHHostTrustError.invalidPrompt
        }
        return SSHHostKeyConfirmation(
            destination: promptDestination,
            connectionDestination: destination,
            algorithm: algorithm,
            fingerprint: fingerprint,
            openSSHPrompt: openSSHPrompt
        )
    }

    private struct TemporaryState {
        let directory: URL
        let helper: URL
        let observedPrompt: URL
        let approvedPrompt: URL
        let expectedKeyIdentity: URL
    }

    private func withTemporaryState<T>(
        _ operation: (TemporaryState) throws -> T
    ) throws -> T {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "ghosthub-ssh-trust-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? fileManager.removeItem(at: directory) }
            let state = TemporaryState(
                directory: directory,
                helper: directory.appendingPathComponent("askpass"),
                observedPrompt: directory.appendingPathComponent("observed"),
                approvedPrompt: directory.appendingPathComponent("approved"),
                expectedKeyIdentity:
                directory.appendingPathComponent("expected-key")
            )
            try Data(Self.askPassScript.utf8).write(
                to: state.helper,
                options: .atomic
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: state.helper.path
            )
            return try operation(state)
        } catch let error as SSHHostTrustError {
            throw error
        } catch {
            throw SSHHostTrustError.temporaryStateUnavailable
        }
    }

    private func readPrompt(at url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static let askPassScript = """
    #!/bin/sh
    set -eu
    umask 077
    candidate_path="$GHOSTHUB_SSH_PROMPT_PATH.candidate.$$"
    identity_path="$GHOSTHUB_SSH_PROMPT_PATH.identity"
    /usr/bin/printf '%s' "$1" > "$candidate_path"
    /usr/bin/awk '
    {
        quote = sprintf("%c", 39)
        host_prefix = "The authenticity of host " quote
        host_suffix = quote " can" quote "t be established."
        host_position = index($0, host_prefix)
        if (host_position > 0) {
            logical_host = substr($0, host_position + length(host_prefix))
            suffix_position = index(logical_host, host_suffix)
            if (suffix_position > 0) {
                logical_host = substr(logical_host, 1, suffix_position - 1)
                sub(/ \\([^)]*\\)$/, "", logical_host)
            }
        }
        colon_marker = " key fingerprint is: "
        plain_marker = " key fingerprint is "
        marker = index($0, colon_marker) ? colon_marker : plain_marker
        position = index($0, marker)
        if (position > 0) {
            algorithm = substr($0, 1, position - 1)
            fingerprint = substr($0, position + length(marker))
            sub(/^[[:space:]]+/, "", algorithm)
            sub(/[[:space:]]+$/, "", algorithm)
            sub(/^[[:space:]]+/, "", fingerprint)
            sub(/[[:space:].]+$/, "", fingerprint)
            print logical_host
            print algorithm
            print fingerprint
            exit
        }
    }
    ' "$candidate_path" > "$identity_path"
    if [ ! -s "$identity_path" ]; then
        /bin/rm -f "$candidate_path" "$identity_path"
        exit 1
    fi
    /bin/mv -f "$candidate_path" "$GHOSTHUB_SSH_PROMPT_PATH"
    if [ -n "${GHOSTHUB_SSH_EXPECTED_KEY_PATH:-}" ] && \
       /usr/bin/cmp -s "$identity_path" \
       "$GHOSTHUB_SSH_EXPECTED_KEY_PATH"; then
        : > "$GHOSTHUB_SSH_APPROVED_PROMPT_PATH"
        /bin/rm -f "$GHOSTHUB_SSH_PROMPT_PATH" "$identity_path"
        /usr/bin/printf 'yes\\n'
    else
        /bin/rm -f "$identity_path"
        /usr/bin/printf 'no\\n'
    fi
    """

    private static func runAskPass(
        host: SSHHostInfo,
        precedingProxyHops: [SSHHostInfo],
        helper: URL,
        observedPrompt: URL,
        approvedPrompt: URL,
        expectedKeyIdentity: URL?
    ) {
        var arguments = [
            "-T",
            "-o", "BatchMode=no",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "UpdateHostKeys=no",
            "-o", "PubkeyAuthentication=no",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "HostbasedAuthentication=no",
            "-o", "GSSAPIAuthentication=no",
        ]
        arguments.append(contentsOf: tmuxSSHConnectionArguments())
        arguments.append(contentsOf: SSHConnectionPool.proxyArguments(
            for: SSHAuthenticationTarget(
                host: host,
                precedingProxyHops: precedingProxyHops
            )
        ))
        if let port = host.port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        let target = host.user.map { "\($0)@\(host.hostname)" }
            ?? host.hostname
        arguments.append(contentsOf: ["-N", "--", target])

        var environment = [
            "SSH_ASKPASS": helper.path,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": "ghosthub",
            "GHOSTHUB_SSH_PROMPT_PATH": observedPrompt.path,
            "GHOSTHUB_SSH_APPROVED_PROMPT_PATH": approvedPrompt.path,
            "GHOSTHUB_SSH_EXPECTED_KEY_PATH": "",
        ]
        if let expectedKeyIdentity {
            environment["GHOSTHUB_SSH_EXPECTED_KEY_PATH"] =
                expectedKeyIdentity.path
        }
        _ = TmuxBinaryResolver.runProcessInLoginShell(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            timeout: 12,
            accountShell: TmuxBinaryResolver.loginShell(),
            environmentOverrides: environment
        )
    }
}
