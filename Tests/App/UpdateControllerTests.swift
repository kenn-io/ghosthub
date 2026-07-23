import Foundation
import Testing
@testable import GhosthubApp

@Suite("Application updates")
struct UpdateControllerTests {
    @Test("accepts a secure feed and a 32-byte Ed25519 public key")
    func acceptsReleaseConfiguration() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let configuration = UpdateConfiguration(infoDictionary: [
            UpdateConfiguration.feedURLKey:
                "https://github.com/kenn-io/ghosthub/releases/latest/"
                + "download/appcast.xml",
            UpdateConfiguration.publicKeyKey: key,
        ])

        #expect(configuration.isReady)
        #expect(configuration.feedURL?.scheme == "https")
        #expect(configuration.publicKey?.count == 32)
    }

    @Test(
        "rejects incomplete or insecure release configuration",
        arguments: [
            [:],
            [
                UpdateConfiguration.feedURLKey:
                    "http://example.com/appcast.xml",
                UpdateConfiguration.publicKeyKey:
                    Data(repeating: 1, count: 32).base64EncodedString(),
            ],
            [
                UpdateConfiguration.feedURLKey:
                    "https://example.com/appcast.xml",
                UpdateConfiguration.publicKeyKey: "not-a-public-key",
            ],
        ]
    )
    func rejectsInvalidConfiguration(
        infoDictionary: [String: String]
    ) {
        #expect(
            !UpdateConfiguration(
                infoDictionary: infoDictionary
            ).isReady
        )
    }
}
