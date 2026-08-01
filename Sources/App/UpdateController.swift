#if canImport(AppKit)
import Foundation
import Sparkle

struct UpdateConfiguration: Equatable {
    static let feedURLKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"
    static let requireSignedFeedKey = "SURequireSignedFeed"
    /// Sparkle 2.9.4 declares this exact Info.plist key as
    /// SUSignedFeedFailureExpirationIntervalKey in SUConstants.m.
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
final class UpdateInstallationDelegate: NSObject, SPUUpdaterDelegate {
    private var refreshRestorationState: () -> Void
    private var authorizeTermination: () -> Void
    private var clearTerminationAuthorization: () -> Void
    private var isRelaunchPending = false

    init(
        refreshRestorationState: @escaping () -> Void = {},
        authorizeTermination: @escaping () -> Void = {},
        clearTerminationAuthorization: @escaping () -> Void = {}
    ) {
        self.refreshRestorationState = refreshRestorationState
        self.authorizeTermination = authorizeTermination
        self.clearTerminationAuthorization = clearTerminationAuthorization
        super.init()
    }

    func configure(
        refreshRestorationState: @escaping () -> Void,
        authorizeTermination: @escaping () -> Void,
        clearTerminationAuthorization: @escaping () -> Void
    ) {
        self.refreshRestorationState = refreshRestorationState
        self.authorizeTermination = authorizeTermination
        self.clearTerminationAuthorization = clearTerminationAuthorization
    }

    func prepareForRelaunch() {
        isRelaunchPending = true
        refreshRestorationState()
        authorizeTermination()
    }

    func updateSessionDidAbort() {
        isRelaunchPending = false
        clearTerminationAuthorization()
    }

    func updateSessionDidFinish(error: Bool) {
        // A successful cycle-finish callback can race ahead of the updater's
        // termination request; disarming here would resurface the quit
        // confirmation mid-relaunch.
        guard error || !isRelaunchPending else { return }
        isRelaunchPending = false
        clearTerminationAuthorization()
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        prepareForRelaunch()
    }

    func updater(
        _ updater: SPUUpdater,
        didAbortWithError error: any Error
    ) {
        updateSessionDidAbort()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        updateSessionDidFinish(error: error != nil)
    }
}

@MainActor
final class UpdateController {
    private let installationDelegate: UpdateInstallationDelegate?
    private let controller: SPUStandardUpdaterController?
    private var didStart = false

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        guard UpdateConfiguration(
            infoDictionary: infoDictionary
        ).isReady else {
            installationDelegate = nil
            controller = nil
            return
        }

        let installationDelegate = UpdateInstallationDelegate()
        self.installationDelegate = installationDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: installationDelegate,
            userDriverDelegate: nil
        )
    }

    var isAvailable: Bool {
        controller != nil
    }

    func configureRelaunch(
        refreshRestorationState: @escaping () -> Void,
        authorizeTermination: @escaping () -> Void,
        clearTerminationAuthorization: @escaping () -> Void
    ) {
        installationDelegate?.configure(
            refreshRestorationState: refreshRestorationState,
            authorizeTermination: authorizeTermination,
            clearTerminationAuthorization: clearTerminationAuthorization
        )
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
