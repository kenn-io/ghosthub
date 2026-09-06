import AppKit
import Sparkle

/// Uses Sparkle's native UI and installer, refreshing resumable offers on demand.
@MainActor
final class UpdateUserDriver: SPUStandardUserDriver {
    weak var updater: SPUUpdater?
    private let latestVersion: () async throws -> String?

    private lazy var refresh = ManualUpdateRefresh(
        latestVersion: latestVersion,
        checkAgain: { [weak self] in self?.updater?.checkForUpdates() },
        showChecking: { [weak self] cancel in
            self?.presentChecking(cancel: cancel)
        },
        showError: { [weak self] error, acknowledge in
            self?.presentRefreshError(error, acknowledge: acknowledge)
        }
    )

    init(
        hostBundle: Bundle,
        delegate: (any SPUStandardUserDriverDelegate)?,
        latestVersion: @escaping () async throws -> String?
    ) {
        self.latestVersion = latestVersion
        super.init(hostBundle: hostBundle, delegate: delegate)
    }

    func checkForUpdates() {
        refresh.checkForUpdates()
    }

    func updateCycleDidFinish() {
        refresh.updateCycleDidFinish()
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        refresh.receiveOffer(
            version: appcastItem.versionString,
            resuming: state.stage != .notDownloaded,
            show: { [weak self] in
                self?.presentOffer(appcastItem, state: state, reply: reply)
            },
            skip: { [weak self] in
                self?.dismissUpdateInstallation()
                reply(.skip)
            }
        )
    }

    override func showReady(
        toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        refresh.receiveReadyOffer(
            show: { [weak self] in self?.presentReadyOffer(reply: reply) },
            skip: { [weak self] in
                self?.dismissUpdateInstallation()
                reply(.skip)
            }
        )
    }

    private func presentReadyOffer(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        super.dismissUpdateInstallation()
        super.showReady(toInstallAndRelaunch: { [weak self] choice in
            self?.refresh.userDidChoose()
            reply(choice)
        })
    }

    private func presentOffer(
        _ item: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        super.dismissUpdateInstallation()
        super.showUpdateFound(with: item, state: state) { [weak self] choice in
            self?.refresh.userDidChoose()
            reply(choice)
        }
    }

    private func presentChecking(cancel: @escaping () -> Void) {
        super.dismissUpdateInstallation()
        super.showUserInitiatedUpdateCheck(cancellation: cancel)
    }

    private func presentRefreshError(
        _ error: any Error,
        acknowledge: @escaping () -> Void
    ) {
        super.dismissUpdateInstallation()
        let notice = NSError(
            domain: "com.ghosthub.updates",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Couldn’t check for a newer update.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "The previously found update is still available. "
                    + error.localizedDescription,
            ]
        )
        super.showUpdaterError(notice, acknowledgement: acknowledge)
    }
}
