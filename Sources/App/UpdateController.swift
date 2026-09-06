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
    var updateCycleFinished: () -> Void = {}
    private var prepareRelaunch: () -> Void
    private var cancelRelaunch: () -> Void
    private var authorizeTermination: () -> Void
    private var clearTerminationAuthorization: () -> Void
    private var isRelaunchPending = false

    init(
        prepareRelaunch: @escaping () -> Void = {},
        cancelRelaunch: @escaping () -> Void = {},
        authorizeTermination: @escaping () -> Void = {},
        clearTerminationAuthorization: @escaping () -> Void = {}
    ) {
        self.prepareRelaunch = prepareRelaunch
        self.cancelRelaunch = cancelRelaunch
        self.authorizeTermination = authorizeTermination
        self.clearTerminationAuthorization = clearTerminationAuthorization
        super.init()
    }

    func configure(
        prepareRelaunch: @escaping () -> Void,
        cancelRelaunch: @escaping () -> Void,
        authorizeTermination: @escaping () -> Void,
        clearTerminationAuthorization: @escaping () -> Void
    ) {
        self.prepareRelaunch = prepareRelaunch
        self.cancelRelaunch = cancelRelaunch
        self.authorizeTermination = authorizeTermination
        self.clearTerminationAuthorization = clearTerminationAuthorization
    }

    func prepareForRelaunch() {
        isRelaunchPending = true
        prepareRelaunch()
        authorizeTermination()
    }

    func updateSessionDidAbort() {
        let shouldCancelRelaunch = isRelaunchPending
        isRelaunchPending = false
        if shouldCancelRelaunch {
            cancelRelaunch()
        }
        clearTerminationAuthorization()
    }

    func updateSessionDidFinish(error: Bool) {
        // A successful cycle-finish callback can race ahead of the updater's
        // termination request; disarming here would resurface the quit
        // confirmation mid-relaunch.
        guard error || !isRelaunchPending else { return }
        let shouldCancelRelaunch = isRelaunchPending
        isRelaunchPending = false
        if shouldCancelRelaunch {
            cancelRelaunch()
        }
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
        updateCycleFinished()
    }
}

@MainActor
final class UpdateController {
    private let installationDelegate: UpdateInstallationDelegate?
    private let updater: SPUUpdater?
    private let userDriver: UpdateUserDriver?
    private let versionDisplay: NightlyUpdateVersionDisplay?
    private var didStart = false

    init(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) {
        let configuration = UpdateConfiguration(
            infoDictionary: infoDictionary
        )
        guard configuration.isReady else {
            installationDelegate = nil
            updater = nil
            userDriver = nil
            versionDisplay = nil
            return
        }

        let installationDelegate = UpdateInstallationDelegate()
        self.installationDelegate = installationDelegate
        let versionDisplay = infoDictionary["GhosthubReleaseChannel"] as? String == "nightly"
            ? NightlyUpdateVersionDisplay(infoDictionary: infoDictionary) : nil
        self.versionDisplay = versionDisplay
        let feed = UpdateFeed(configuration: configuration)
        let userDriver = UpdateUserDriver(
            hostBundle: .main,
            delegate: versionDisplay,
            latestVersion: { try await feed.latestVersion() }
        )
        self.userDriver = userDriver
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: installationDelegate
        )
        self.updater = updater
        userDriver.updater = updater
        installationDelegate.updateCycleFinished = { [weak userDriver] in
            userDriver?.updateCycleDidFinish()
        }
    }

    var isAvailable: Bool {
        updater != nil
    }

    func configureRelaunch(
        prepareRelaunch: @escaping () -> Void,
        cancelRelaunch: @escaping () -> Void,
        authorizeTermination: @escaping () -> Void,
        clearTerminationAuthorization: @escaping () -> Void
    ) {
        installationDelegate?.configure(
            prepareRelaunch: prepareRelaunch,
            cancelRelaunch: cancelRelaunch,
            authorizeTermination: authorizeTermination,
            clearTerminationAuthorization: clearTerminationAuthorization
        )
    }

    func start() {
        guard !didStart, let updater else { return }
        do {
            try updater.start()
            didStart = true
        } catch {
            userDriver?.showUpdaterError(error, acknowledgement: {})
        }
    }

    func checkForUpdates() {
        start()
        guard didStart else { return }
        userDriver?.checkForUpdates()
    }
}
#endif
