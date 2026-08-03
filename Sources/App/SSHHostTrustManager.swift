import Foundation
import GhosthubSettings
import GhosthubTmux

enum SSHHostTrustError: Error, Equatable, LocalizedError {
    case invalidPrompt
    case hostKeyChanged
    case hostKeyWasNotSaved
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
        URL?
    ) -> Void

    private let askPassRunner: AskPassRunner

    init(
        askPassRunner: @escaping AskPassRunner = Self.runAskPass
    ) {
        self.askPassRunner = askPassRunner
    }

    func pendingConfirmation(
        for host: SSHHostInfo,
        destination: String
    ) throws -> SSHHostKeyConfirmation? {
        try withTemporaryState { state in
            askPassRunner(
                host,
                state.helper,
                state.observedPrompt,
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
    ) throws {
        guard confirmation.destination == destination else {
            throw SSHHostTrustError.hostKeyChanged
        }
        try withTemporaryState { state in
            try Data(confirmation.openSSHPrompt.utf8).write(
                to: state.expectedPrompt,
                options: .atomic
            )
            askPassRunner(
                host,
                state.helper,
                state.observedPrompt,
                state.expectedPrompt
            )
            guard let observed = try readPrompt(at: state.observedPrompt),
                  observed == confirmation.openSSHPrompt
            else {
                throw SSHHostTrustError.hostKeyChanged
            }
        }

        if let pending = try pendingConfirmation(
            for: host,
            destination: destination
        ) {
            if pending.openSSHPrompt != confirmation.openSSHPrompt {
                throw SSHHostTrustError.hostKeyChanged
            }
            throw SSHHostTrustError.hostKeyWasNotSaved
        }
    }

    static func confirmation(
        destination: String,
        openSSHPrompt: String
    ) throws -> SSHHostKeyConfirmation {
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
            destination: destination,
            algorithm: algorithm,
            fingerprint: fingerprint,
            openSSHPrompt: openSSHPrompt
        )
    }

    private struct TemporaryState {
        let directory: URL
        let helper: URL
        let observedPrompt: URL
        let expectedPrompt: URL
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
                expectedPrompt: directory.appendingPathComponent("expected")
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

    private static let askPassScript = """
    #!/bin/sh
    set -eu
    umask 077
    /usr/bin/printf '%s' "$1" > "$GHOSTHUB_SSH_PROMPT_PATH"
    if [ -n "${GHOSTHUB_SSH_EXPECTED_PROMPT_PATH:-}" ] && \
       /usr/bin/cmp -s "$GHOSTHUB_SSH_PROMPT_PATH" \
       "$GHOSTHUB_SSH_EXPECTED_PROMPT_PATH"; then
        /usr/bin/printf 'yes\\n'
    else
        /usr/bin/printf 'no\\n'
    fi
    """

    private static func runAskPass(
        host: SSHHostInfo,
        helper: URL,
        observedPrompt: URL,
        expectedPrompt: URL?
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
            "GHOSTHUB_SSH_EXPECTED_PROMPT_PATH": "",
        ]
        if let expectedPrompt {
            environment["GHOSTHUB_SSH_EXPECTED_PROMPT_PATH"] =
                expectedPrompt.path
        }
        _ = TmuxBinaryResolver.runProcess(
            executable: "/usr/bin/ssh",
            arguments: arguments,
            timeout: 12,
            environmentOverrides: environment
        )
    }
}
