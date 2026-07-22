import Combine
import Foundation
import Testing
@testable import GhosthubTerminalSupport

private extension GhosttyRuntimeState {
    func recordActions(
        _ actions: GhosttyRuntimeActionEvent...
    ) {
        for action in actions {
            recordAction(action)
        }
    }
}

@MainActor
struct GhosttyRuntimeStateTests {
    var state = GhosttyRuntimeState()

    @Test("recordAction updates the last action")
    func recordActionUpdatesLastAction() {
        state.recordAction(.quit)
        #expect(state.lastAction == .quit)

        state.recordAction(.ringBell)
        #expect(state.lastAction == .ringBell)
    }

    @Test("recordWakeup increments the count")
    func recordWakeupIncrementsCount() {
        #expect(state.wakeupCount == 0)

        state.recordWakeup()
        #expect(state.wakeupCount == 1)

        state.recordWakeup()
        #expect(state.wakeupCount == 2)
    }

    @Test("childExitSubject receives childExited actions")
    func childExitSubjectReceivesChildExitedAction() {
        let action = GhosttyRuntimeActionEvent.childExited(
            exitCode: 0,
            runtimeMS: 5000
        )

        let received = collectEvents(from: state.childExitSubject) {
            state.recordAction(action)
        }

        #expect(received == [action])
    }

    @Test("childExitSubject ignores non-child actions")
    func childExitSubjectDoesNotReceiveNonChildActions() {
        let received = collectEvents(from: state.childExitSubject) {
            state.recordActions(
                .quit, .ringBell, .render, .newSplit(.right)
            )
        }

        #expect(received.isEmpty)
    }

    @Test("splitActionSubject receives split actions")
    func splitActionSubjectReceivesSplitActions() {
        let received = collectEvents(from: state.splitActionSubject) {
            state.recordAction(
                .newSplit(.right), sourceSurfaceIdentity: 41
            )
            state.recordAction(.gotoSplit(.left))
            state.recordAction(.resizeSplit(.up, 10))
            state.recordAction(.equalizeSplits)
            state.recordAction(.toggleSplitZoom)
        }

        let expected: [GhosttyRuntimeSplitAction] = [
            GhosttyRuntimeSplitAction(
                action: .newSplit(.right),
                sourceSurfaceIdentity: 41
            ),
            GhosttyRuntimeSplitAction(action: .gotoSplit(.left)),
            GhosttyRuntimeSplitAction(action: .resizeSplit(.up, 10)),
            GhosttyRuntimeSplitAction(action: .equalizeSplits),
            GhosttyRuntimeSplitAction(action: .toggleSplitZoom),
        ]
        #expect(received == expected)
    }

    @Test("splitActionSubject ignores non-split actions")
    func splitActionSubjectDoesNotReceiveNonSplitActions() {
        let received = collectEvents(from: state.splitActionSubject) {
            state.recordActions(
                .quit, .render,
                .childExited(exitCode: 1, runtimeMS: 100),
                .setTitle("foo")
            )
        }

        #expect(received.isEmpty)
    }

    @Test("recordClose appends events")
    func recordCloseAppendsEvent() {
        #expect(state.closeEvents.isEmpty)

        state.recordClose(processAlive: true)
        #expect(state.closeEvents.count == 1)
        #expect(state.closeEvents[0].processAlive)

        state.recordClose(processAlive: false)
        #expect(state.closeEvents.count == 2)
        #expect(!state.closeEvents[1].processAlive)
    }
}
