@preconcurrency import Combine
import Foundation
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubWorkspace
#if canImport(AppKit)
import AppKit
#endif

extension WorkspaceSceneModel {

    func subscribeChildExitEvents() {
        childExitCancellable = terminalRuntime.runtimeState
            .childExitSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] action in
                self?.handleChildExit(action)
            }
    }

    func subscribeAppActivity() {
        #if canImport(AppKit)
        let center = NotificationCenter.default
        appDidBecomeActiveCancellable = center
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleApplicationDidBecomeActiveForResourceMonitoring()
            }
        appDidResignActiveCancellable = center
            .publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleApplicationDidResignActiveForResourceMonitoring()
            }
        #endif
    }

    /// Displays coming or going changes whether an attach can succeed at all,
    /// so a session waiting on one retries the moment the lid opens.
    func subscribeDisplayAvailability() {
        #if canImport(AppKit)
        screenParametersCancellable = NotificationCenter.default
            .publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleDisplayParametersChanged()
            }
        #endif
    }

    func handleApplicationDidBecomeActiveForResourceMonitoring() {
        isAppActive = true
        tmuxSessionPreviewCoordinator.applicationDidBecomeActive()
        activityController
            .handleApplicationDidBecomeActiveForResourceMonitoring()
    }

    func handleApplicationDidResignActiveForResourceMonitoring() {
        isAppActive = false
        tmuxSessionPreviewCoordinator.applicationDidResignActive()
        activityController
            .handleApplicationDidResignActiveForResourceMonitoring()
    }

    private func handleChildExit(
        _ action: LibghosttyRuntimeActionEvent
    ) {
        guard case .childExited = action else { return }
        // TODO: libghostty's child-exit action does not yet carry
        // surface identity, so we cannot determine which worktree
        // the exited process belonged to. Once upstream attaches
        // surface metadata, re-enable notifications here:
        //   notificationService.playCompletionSound()
        //   notificationService.postAgentFinished(...)
    }

}
