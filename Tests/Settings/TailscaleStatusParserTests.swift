import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubSettings

struct TailscaleStatusParserTests {
    @Test("parses peers from tailscale status JSON")
    func parsesPeersFromJSON() throws {
        let json = """
        {
          "Self": {
            "HostName": "my-mac",
            "OS": "macOS",
            "Online": true,
            "DNSName": "my-mac.example.ts.net."
          },
          "Peer": {
            "abc123": {
              "ID": "abc123",
              "HostName": "dev-box",
              "DNSName": "dev-box.example.ts.net.",
              "OS": "linux",
              "Online": true
            },
            "def456": {
              "ID": "def456",
              "HostName": "studio",
              "DNSName": "studio.example.ts.net.",
              "OS": "macOS",
              "Online": false
            },
            "ghi789": {
              "ID": "ghi789",
              "HostName": "phone",
              "DNSName": "phone.example.ts.net.",
              "OS": "iOS",
              "Online": true
            }
          }
        }
        """
        let data = Data(json.utf8)
        let result = TailscaleStatusParser.peers(from: data)
        let peers = try result.get()

        #expect(peers.count == 2)

        let devBox = peers.first { $0.hostName == "dev-box" }
        #expect(devBox != nil)
        #expect(devBox?.sshAddress == "dev-box")
        #expect(devBox?.platform == .linux)
        #expect(devBox?.isOnline == true)
        #expect(devBox?.isSSHCapable == true)

        let studio = peers.first { $0.hostName == "studio" }
        #expect(studio != nil)
        #expect(studio?.platform == .macOS)
        #expect(studio?.isOnline == false)
    }

    @Test("filters out non-SSH-capable peers")
    func filtersNonSSHPeers() throws {
        let json = """
        {
          "Peer": {
            "a": {
              "ID": "a",
              "HostName": "iphone",
              "DNSName": "iphone.ts.net.",
              "OS": "iOS",
              "Online": true
            },
            "b": {
              "ID": "b",
              "HostName": "android",
              "DNSName": "android.ts.net.",
              "OS": "android",
              "Online": true
            },
            "c": {
              "ID": "c",
              "HostName": "windows-pc",
              "DNSName": "windows.ts.net.",
              "OS": "windows",
              "Online": true
            }
          }
        }
        """
        let data = Data(json.utf8)
        let peers = try TailscaleStatusParser
            .peers(from: data).get()
        #expect(peers.map(\.hostName) == ["windows-pc"])
        #expect(peers.first?.platform == .windows)
    }

    @Test("sorts online peers before offline")
    func sortsOnlineFirst() throws {
        let json = """
        {
          "Peer": {
            "a": {
              "ID": "a",
              "HostName": "alpha",
              "DNSName": "alpha.ts.net.",
              "OS": "linux",
              "Online": false
            },
            "b": {
              "ID": "b",
              "HostName": "beta",
              "DNSName": "beta.ts.net.",
              "OS": "linux",
              "Online": true
            }
          }
        }
        """
        let data = Data(json.utf8)
        let peers = try TailscaleStatusParser
            .peers(from: data).get()
        #expect(peers.map(\.hostName) == ["beta", "alpha"])
    }

    @Test("handles empty peer list")
    func handlesEmptyPeers() throws {
        let json = """
        { "Peer": {} }
        """
        let data = Data(json.utf8)
        let peers = try TailscaleStatusParser
            .peers(from: data).get()
        #expect(peers.isEmpty)
    }

    @Test("handles missing Peer key")
    func handlesMissingPeerKey() throws {
        let json = """
        { "Self": { "HostName": "me" } }
        """
        let data = Data(json.utf8)
        let peers = try TailscaleStatusParser
            .peers(from: data).get()
        #expect(peers.isEmpty)
    }

    @Test("returns parse error for invalid JSON")
    func returnsParseError() {
        let data = Data("not json".utf8)
        let result = TailscaleStatusParser
            .peers(from: data)
        guard case .failure(.parseFailed) = result else {
            Issue.record("expected parseFailed error")
            return
        }
    }
}
