import Foundation
import NIOSSH

struct RemoteTmuxConfiguration: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let trustedHostKey: NIOSSHPublicKey
    let sessionName: String

    init(
        host: String,
        port: String,
        username: String,
        password: String,
        trustedHostKey: String,
        sessionName: String
    ) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !host.isEmpty else { throw RemoteTmuxConfigurationError.missingHost }
        guard let port = Int(port), (1 ... 65_535).contains(port) else {
            throw RemoteTmuxConfigurationError.invalidPort
        }
        guard !username.isEmpty else {
            throw RemoteTmuxConfigurationError.missingUsername
        }
        guard !password.isEmpty else {
            throw RemoteTmuxConfigurationError.missingPassword
        }
        guard !sessionName.isEmpty else {
            throw RemoteTmuxConfigurationError.missingSession
        }

        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.trustedHostKey = try Self.parseHostKey(trustedHostKey)
        self.sessionName = sessionName
    }

    var remoteCommand: String {
        let target = Self.shellQuote("=\(sessionName)")
        let body = "unset TMUX TMUX_PANE; exec tmux attach-session -E -t \(target)"
        return "exec \"${SHELL:-/bin/sh}\" -lc \(Self.shellQuote(body))"
    }

    private static func parseHostKey(_ value: String) throws -> NIOSSHPublicKey {
        let fields = value.split(whereSeparator: \Character.isWhitespace)
        let supportedPrefixes = ["ssh-ed25519", "ecdsa-sha2-"]
        guard let algorithmIndex = fields.firstIndex(where: { field in
            supportedPrefixes.contains { field.hasPrefix($0) }
        }), fields.indices.contains(algorithmIndex + 1)
        else {
            throw RemoteTmuxConfigurationError.invalidHostKey
        }

        let openSSHKey = "\(fields[algorithmIndex]) \(fields[algorithmIndex + 1])"
        do {
            return try NIOSSHPublicKey(openSSHPublicKey: openSSHKey)
        } catch {
            throw RemoteTmuxConfigurationError.invalidHostKey
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum RemoteTmuxConfigurationError: LocalizedError, Equatable {
    case missingHost
    case invalidPort
    case missingUsername
    case missingPassword
    case invalidHostKey
    case missingSession

    var errorDescription: String? {
        switch self {
        case .missingHost:
            "Enter the SSH host."
        case .invalidPort:
            "Enter an SSH port from 1 through 65535."
        case .missingUsername:
            "Enter the SSH username."
        case .missingPassword:
            "Enter the SSH password. It is retained only for this app session."
        case .invalidHostKey:
            "Paste a trusted Ed25519 or ECDSA OpenSSH host public-key line."
        case .missingSession:
            "Enter the exact existing tmux session name."
        }
    }
}
