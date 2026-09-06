import CryptoKit
import Foundation
import Testing
@testable import GhosthubApp

@Suite("Fresh update feed")
struct UpdateFeedTests {
    @Test("reads the build version from a verified release feed")
    func latestRelease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let feed = try signedFeed(key: key)

        #expect(try latestVersion(feed, key: key) == "200")
    }

    @Test("rejects changed content and signatures from another key")
    func rejectsUnverifiedFeed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let feed = try signedFeed(key: key)
        let tampered = Data(String(decoding: feed, as: UTF8.self)
            .replacingOccurrences(of: ">200<", with: ">300<").utf8)

        #expect(throws: (any Error).self) {
            try latestVersion(tampered, key: key)
        }
        #expect(throws: (any Error).self) {
            try latestVersion(feed, key: Curve25519.Signing.PrivateKey())
        }
    }

    @Test("requires the signed length to cover the release XML")
    func rejectsWrongLength() throws {
        let key = Curve25519.Signing.PrivateKey()
        let feed = try signedFeed(key: key, length: 0)

        #expect(throws: (any Error).self) {
            try latestVersion(feed, key: key)
        }
    }

    @Test("preserves a queued update when the sole release is incompatible", arguments: [
        "<sparkle:minimumSystemVersion>16</sparkle:minimumSystemVersion>",
        "<sparkle:maximumSystemVersion>14</sparkle:maximumSystemVersion>",
        "<sparkle:minimumUpdateVersion>101</sparkle:minimumUpdateVersion>",
        "<sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>",
    ])
    func incompatibleRelease(requirement: String) throws {
        let key = Curve25519.Signing.PrivateKey()
        let feed = try signedFeed(key: key, requirements: requirement)

        #expect(try latestVersion(feed, key: key) == nil)
    }

    @Test("accepts satisfied requirements at their inclusive boundaries")
    func compatibleRelease() throws {
        let key = Curve25519.Signing.PrivateKey()
        let feed = try signedFeed(key: key, requirements: """
        <sparkle:minimumSystemVersion>15</sparkle:minimumSystemVersion>
        <sparkle:maximumSystemVersion>15</sparkle:maximumSystemVersion>
        <sparkle:minimumUpdateVersion>100</sparkle:minimumUpdateVersion>
        <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
        """)

        #expect(try UpdateFeed.latestVersion(
            in: feed, publicKey: key.publicKey.rawRepresentation,
            installedVersion: "100", systemVersion: "15", isAppleSilicon: true
        ) == "200")
    }

    @Test("does not guess between multiple update enclosures")
    func rejectsMultipleEnclosures() throws {
        let key = Curve25519.Signing.PrivateKey()
        let feed = try signedFeed(
            key: key,
            requirements: "<enclosure url=\"https://example.com/other.dmg\" />"
        )

        #expect(throws: (any Error).self) {
            try latestVersion(feed, key: key)
        }
    }

    @Test("requires an archive URL and signature even in a signed feed", arguments: [
        "<enclosure sparkle:edSignature=\"\(Data(repeating: 0, count: 64).base64EncodedString())\" />",
        "<enclosure url=\"https://example.com/release.dmg\" />",
    ])
    func rejectsIncompleteEnclosure(enclosure: String) throws {
        let key = Curve25519.Signing.PrivateKey()
        let feed = try signedFeed(key: key, enclosure: enclosure)

        #expect(throws: (any Error).self) {
            try latestVersion(feed, key: key)
        }
    }

    private func latestVersion(_ feed: Data, key: Curve25519.Signing.PrivateKey) throws -> String? {
        try UpdateFeed.latestVersion(
            in: feed, publicKey: key.publicKey.rawRepresentation,
            installedVersion: "100", systemVersion: "15", isAppleSilicon: false
        )
    }

    private func signedFeed(
        key: Curve25519.Signing.PrivateKey,
        requirements: String = "",
        length: Int? = nil,
        enclosure: String? = nil
    ) throws -> Data {
        let archiveSignature = try key.signature(for: Data("release archive fixture".utf8))
            .base64EncodedString()
        let releaseEnclosure = enclosure ?? """
        <enclosure url="https://example.com/release.dmg" length="123" type="application/octet-stream" sparkle:edSignature="\(
            archiveSignature
        )" />
        """
        let content = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel><item>
            <sparkle:version>200</sparkle:version>
            <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
            \(requirements)
            \(releaseEnclosure)
          </item></channel>
        </rss>

        """.utf8)
        let signature = try key.signature(for: content).base64EncodedString()
        return content + Data("""
        <!-- sparkle-signatures:
        edSignature: \(signature)
        length: \(length ?? content.count)
        -->
        """.utf8)
    }
}
