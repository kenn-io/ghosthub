import Foundation
import GhosthubSettings
import GhosthubTmux

enum SSHHostTrustError: Error, Equatable, LocalizedError {
    case invalidPrompt
    case hostKeyChanged
    case hostKeyWasNotSaved
    case strictHostKeyPolicyUnavailable
    case strictHostKeyPolicyUnsupported(String)
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
        case .temporaryStateUnavailable:
            return "Ghosthub could not prepare secure temporary state for SSH"
                + " host-key confirmation."
        }
    }
}

struct SSHHostTrustManager: Sendable {
    typealias AskPassRunner = @Sendable (
        SSHHostInfo,
        URL,
        URL,
        URL,
        URL?
    ) -> Void
    typealias StrictHostKeyPolicyProvider = @Sendable (SSHHostInfo) -> String?

    private let askPassRunner: AskPassRunner
    private let strictHostKeyPolicyProvider: StrictHostKeyPolicyProvider

    init(
        askPassRunner: @escaping AskPassRunner = Self.runAskPass,
        strictHostKeyPolicyProvider:
        @escaping StrictHostKeyPolicyProvider = {
            SSHConfigurationResolver.configuration(for: $0)?
                .strictHostKeyChecking
        }
    ) {
        self.askPassRunner = askPassRunner
        self.strictHostKeyPolicyProvider = strictHostKeyPolicyProvider
    }

    func pendingConfirmation(
        for host: SSHHostInfo,
        destination: String
    ) throws -> SSHHostKeyConfirmation? {
        try validateStrictHostKeyPolicy(for: host)
        return try withTemporaryState { state -> SSHHostKeyConfirmation? in
            askPassRunner(
                host,
                state.helper,
                state.observedPrompt,
                state.approvedPrompt,
                nil
            )
            guard let prompt = try readPrompt(at: state.observedPrompt) else {
                return nil
            }
            return try Self.confirmation(
                destination: destination,
                openSSHPrompt: prompt
            )
        }
    }

    func accept(
        _ confirmation: SSHHostKeyConfirmation,
        for host: SSHHostInfo,
        destination: String
    ) throws -> SSHHostKeyConfirmation? {
        guard confirmation.connectionDestination == destination else {
            throw SSHHostTrustError.hostKeyChanged
        }
        try validateStrictHostKeyPolicy(for: host)
        try withTemporaryState { state in
            try Data(Self.keyIdentity(for: confirmation).utf8).write(
                to: state.expectedKeyIdentity,
                options: .atomic
            )
            askPassRunner(
                host,
                state.helper,
                state.observedPrompt,
                state.approvedPrompt,
                state.expectedKeyIdentity
            )
            guard FileManager.default.fileExists(
                atPath: state.approvedPrompt.path
            ) else {
                throw SSHHostTrustError.hostKeyChanged
            }
        }

        if let pending = try pendingConfirmation(
            for: host,
            destination: destination
        ) {
            if pending.algorithm == confirmation.algorithm,
               pending.fingerprint == confirmation.fingerprint,
               Self.logicalHost(pending.destination)
               == Self.logicalHost(confirmation.destination) {
                throw SSHHostTrustError.hostKeyWasNotSaved
            }
            return pending
        }
        return nil
    }

    private func validateStrictHostKeyPolicy(
        for host: SSHHostInfo
    ) throws {
        guard let policy = strictHostKeyPolicyProvider(host)?
            .lowercased() else {
            throw SSHHostTrustError.strictHostKeyPolicyUnavailable
        }
        guard policy == "ask" || policy == "accept-new" else {
            throw SSHHostTrustError.strictHostKeyPolicyUnsupported(policy)
        }
    }

    private static func keyIdentity(
        for confirmation: SSHHostKeyConfirmation
    ) -> String {
        "\(confirmation.algorithm)\n\(confirmation.fingerprint)\n"
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
    /usr/bin/printf '%s' "$1" > "$GHOSTHUB_SSH_PROMPT_PATH"
    identity_path="$GHOSTHUB_SSH_PROMPT_PATH.identity"
    /usr/bin/awk '
    {
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
            print algorithm
            print fingerprint
            exit
        }
    }
    ' "$GHOSTHUB_SSH_PROMPT_PATH" > "$identity_path"
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
        if let port = host.port, port != 22 {
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
