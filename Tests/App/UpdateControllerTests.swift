import Foundation
import Testing
@testable import GhosthubApp

@Suite("Application updates")
struct UpdateControllerTests {
    enum InvalidConfiguration: CaseIterable, Sendable {
        case incomplete
        case insecureFeed
        case invalidKey
        case expiringFeedFailure
        case unsignedFeedAllowed
        case verificationAfterExtraction
    }

    @Test("accepts the complete signed-update policy")
    func acceptsReleaseConfiguration() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let configuration = UpdateConfiguration(infoDictionary: [
            UpdateConfiguration.feedURLKey:
                "https://github.com/kenn-io/ghosthub/releases/latest/"
                + "download/appcast.xml",
            UpdateConfiguration.publicKeyKey: key,
            UpdateConfiguration.requireSignedFeedKey: true,
            UpdateConfiguration.signedFeedFailureExpirationKey: 0,
            UpdateConfiguration.verifyBeforeExtractionKey: true,
        ])

        #expect(configuration.isReady)
        #expect(configuration.feedURL?.scheme == "https")
        #expect(configuration.publicKey?.count == 32)
    }

    @Test(
        "rejects incomplete or insecure release configuration",
        arguments: InvalidConfiguration.allCases
    )
    func rejectsInvalidConfiguration(
        invalidConfiguration: InvalidConfiguration
    ) {
        var infoDictionary: [String: Any] = [
            UpdateConfiguration.feedURLKey:
                "https://example.com/appcast.xml",
            UpdateConfiguration.publicKeyKey:
                Data(repeating: 1, count: 32).base64EncodedString(),
            UpdateConfiguration.requireSignedFeedKey: true,
            UpdateConfiguration.signedFeedFailureExpirationKey: 0,
            UpdateConfiguration.verifyBeforeExtractionKey: true,
        ]

        switch invalidConfiguration {
        case .incomplete:
            infoDictionary = [:]
        case .insecureFeed:
            infoDictionary[UpdateConfiguration.feedURLKey] =
                "http://example.com/appcast.xml"
        case .invalidKey:
            infoDictionary[UpdateConfiguration.publicKeyKey] =
                "not-a-public-key"
        case .expiringFeedFailure:
            infoDictionary[
                UpdateConfiguration.signedFeedFailureExpirationKey
            ] = 20
        case .unsignedFeedAllowed:
            infoDictionary[UpdateConfiguration.requireSignedFeedKey] = false
        case .verificationAfterExtraction:
            infoDictionary[
                UpdateConfiguration.verifyBeforeExtractionKey
            ] = false
        }

        #expect(
            !UpdateConfiguration(
                infoDictionary: infoDictionary
            ).isReady
        )
    }
}
