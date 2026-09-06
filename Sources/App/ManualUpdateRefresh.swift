import Foundation
import Sparkle

/// Keeps a resumable offer until a fresh feed check has found its replacement.
@MainActor
final class ManualUpdateRefresh {
    private struct Offer {
        let version: String
        let show: () -> Void
        let skip: () -> Void
    }

    private let latestVersion: () async throws -> String?
    private let checkAgain: () -> Void
    private let showChecking: (@escaping () -> Void) -> Void
    private let showError: (any Error, @escaping () -> Void) -> Void
    private var offer: Offer?
    private var offeredVersion: String?
    private var requested = false
    private var awaitingCycleFinish = false
    private(set) var task: Task<Void, Never>?

    init(
        latestVersion: @escaping () async throws -> String?,
        checkAgain: @escaping () -> Void,
        showChecking: @escaping (@escaping () -> Void) -> Void,
        showError: @escaping (any Error, @escaping () -> Void) -> Void
    ) {
        self.latestVersion = latestVersion
        self.checkAgain = checkAgain
        self.showChecking = showChecking
        self.showError = showError
    }

    func checkForUpdates() {
        guard task == nil, !awaitingCycleFinish else { return }
        requested = true
        if let offer {
            refresh(offer)
        } else {
            checkAgain()
        }
    }

    func receiveOffer(
        version: String,
        resuming: Bool,
        show: @escaping () -> Void,
        skip: @escaping () -> Void
    ) {
        let offer = Offer(version: version, show: show, skip: skip)
        offeredVersion = version
        self.offer = offer
        if requested, resuming {
            refresh(offer)
        } else {
            requested = false
            show()
        }
    }

    func userDidChoose() {
        offer = nil
    }

    func receiveReadyOffer(show: @escaping () -> Void, skip: @escaping () -> Void) {
        guard let offeredVersion else {
            show()
            return
        }
        receiveOffer(version: offeredVersion, resuming: true, show: show, skip: skip)
    }

    func updateCycleDidFinish() {
        offer = nil
        offeredVersion = nil
        requested = false
        guard awaitingCycleFinish else { return }
        awaitingCycleFinish = false
        checkAgain()
    }

    private func refresh(_ offer: Offer) {
        requested = false
        showChecking { [weak self] in
            self?.task?.cancel()
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                let version = try await latestVersion()
                try Task.checkCancellation()
                if let version,
                   SUStandardVersionComparator.default.compareVersion(
                       version, toVersion: offer.version
                   ) == .orderedDescending {
                    awaitingCycleFinish = true
                    self.offer = nil
                    offer.skip()
                } else {
                    offer.show()
                }
            } catch {
                if Task.isCancelled {
                    offer.show()
                } else {
                    showError(error, offer.show)
                }
            }
        }
    }
}
