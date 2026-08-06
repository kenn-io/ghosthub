import Testing
@testable import RendererSpike

@Suite("Remote tmux configuration")
struct RemoteTmuxConfigurationTests {
    private let publicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJfkNV4OS33ImTXvorZr72q4v5XhVEQKfvqsxOEJ/XaR"

    @Test("known_hosts input and surrounding field whitespace are accepted")
    func knownHostsInput() throws {
        let configuration = try RemoteTmuxConfiguration(
            host: " host.example.com ",
            port: "22",
            username: " kenn ",
            password: "secret",
            trustedHostKey: "host.example.com \(publicKey) host-comment",
            sessionName: " release-work "
        )

        #expect(configuration.host == "host.example.com")
        #expect(configuration.username == "kenn")
        #expect(configuration.sessionName == "release-work")
        #expect(
            configuration.remoteCommand
                == #"exec "${SHELL:-/bin/sh}" -lc 'unset TMUX TMUX_PANE; exec tmux attach-session -E -t '\''=release-work'\'''"#
        )
    }

    @Test("session names remain one exact shell argument")
    func shellQuotedSessionName() throws {
        let configuration = try RemoteTmuxConfiguration(
            host: "host.example.com",
            port: "2222",
            username: "kenn",
            password: "secret",
            trustedHostKey: publicKey,
            sessionName: "release'; echo unsafe"
        )

        #expect(configuration.port == 2222)
        #expect(
            configuration.remoteCommand
                == #"exec "${SHELL:-/bin/sh}" -lc 'unset TMUX TMUX_PANE; exec tmux attach-session -E -t '\''=release'\''\'\'''\''; echo unsafe'\'''"#
        )
    }

    @Test("invalid trust material is rejected before networking")
    func invalidHostKey() {
        #expect(throws: RemoteTmuxConfigurationError.invalidHostKey) {
            try RemoteTmuxConfiguration(
                host: "host.example.com",
                port: "22",
                username: "kenn",
                password: "secret",
                trustedHostKey: "SHA256:not-a-public-key",
                sessionName: "release-work"
            )
        }
    }
}
