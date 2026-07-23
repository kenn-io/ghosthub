#if canImport(AppKit)
import Foundation
import Sparkle

struct UpdateConfiguration: Equatable {
    static let feedURLKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"
    static let requireSignedFeedKey = "SURequireSignedFeed"
    // Sparkle 2.9.4 declares this exact Info.plist key as
    // SUSignedFeedFailureExpirationIntervalKey in SUConstants.m.
    static let signedFeedFailureExpirationKey =
        "SUSignedFeedFailureExpirationInterval"
    static let verifyBeforeExtractionKey =
        "SUVerifyUpdateBeforeExtraction"

    let feedURL: URL?
    let publicKey: Data?
    let requiresSignedFeed: Bool
    let signedFeedFailureExpirationDisabled: Bool
    let verifiesBeforeExtraction: Bool

    init(infoDictionary: [String: Any]) {
        if let rawURL = infoDictionary[Self.feedURLKey] as? String,
           let url = URL(string: rawURL),
           url.scheme == "https" {
            feedURL = url
        } else {
            feedURL = nil
        }

        if let rawKey = infoDictionary[Self.publicKeyKey] as? String,
           let decoded = Data(base64Encoded: rawKey),
           decoded.count == 32 {
            publicKey = decoded
        } else {
            publicKey = nil
        }

        requiresSignedFeed =
            infoDictionary[Self.requireSignedFeedKey] as? Bool == true
        signedFeedFailureExpirationDisabled =
            (infoDictionary[Self.signedFeedFailureExpirationKey]
                as? NSNumber)?.doubleValue == 0
        verifiesBeforeExtraction =
            infoDictionary[Self.verifyBeforeExtractionKey] as? Bool
                == true
    }

    var isReady: Bool {
        feedURL != nil
            && publicKey != nil
            && requiresSignedFeed
            && signedFeedFailureExpirationDisabled
            && verifiesBeforeExtraction
    }
}

@MainActor
final class UpdateController {
    private let controller: SPUStandardUpdaterController?
    private var didStart = false

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        guard UpdateConfiguration(
            infoDictionary: infoDictionary
        ).isReady else {
            controller = nil
            return
        }

        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var isAvailable: Bool {
        controller != nil
    }

    func start() {
        guard !didStart, let controller else { return }
        didStart = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        start()
        controller?.checkForUpdates(nil)
    }
}
#endif
