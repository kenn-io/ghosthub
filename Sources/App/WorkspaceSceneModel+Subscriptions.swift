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

    func handleApplicationDidBecomeActiveForResourceMonitoring() {
        isAppActive = true
        activityController
            .handleApplicationDidBecomeActiveForResourceMonitoring()
        refreshTmuxSessionDiscovery()
    }

    func handleApplicationDidResignActiveForResourceMonitoring() {
        isAppActive = false
        activityController
            .handleApplicationDidResignActiveForResourceMonitoring()
    }

    private func handleChildExit(
        _ action: GhosttyRuntimeActionEvent
    ) {
        guard case .childExited = action else { return }
        // TODO: Ghostty's child-exit action does not yet carry
        // surface identity, so we cannot determine which worktree
        // the exited process belonged to. Once upstream attaches
        // surface metadata, re-enable notifications here:
        //   notificationService.playCompletionSound()
        //   notificationService.postAgentFinished(...)
    }

}
