#if canImport(AppKit)
import Foundation
import Sparkle

struct UpdateConfiguration: Equatable {
    static let feedURLKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"

    let feedURL: URL?
    let publicKey: Data?

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
    }

    var isReady: Bool {
        feedURL != nil && publicKey != nil
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
