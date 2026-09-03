import Foundation
import GhosthubTerminalSupport

final class LibghosttyFindOperationRegistry: @unchecked Sendable {
    static let shared = LibghosttyFindOperationRegistry()

    enum Callback: Equatable {
        case total(Int)
        case selected(Int)
    }

    private struct PendingOperation {
        let token: TerminalFindOperationToken
    }

    private struct OperationState {
        var token: TerminalFindOperationToken?
        var pending: [PendingOperation]
        var receivedResetTotal = false
    }

    private let lock = NSLock()
    private var operations: [UInt: OperationState] = [:]

    func prepareSearch(
        _ operation: TerminalFindOperationToken,
        for surfaceIdentity: UInt
    ) {
        lock.lock()
        defer { lock.unlock() }
        var state = operations[surfaceIdentity] ?? OperationState(
            token: nil,
            pending: []
        )
        state.pending.append(PendingOperation(token: operation))
        state.receivedResetTotal = false
        operations[surfaceIdentity] = state
    }

    func prepareNavigation(
        _ operation: TerminalFindOperationToken,
        for surfaceIdentity: UInt
    ) {
        lock.lock()
        defer { lock.unlock() }
        if var state = operations[surfaceIdentity] {
            state.token = operation
            state.pending.removeAll()
            state.receivedResetTotal = false
            operations[surfaceIdentity] = state
        } else {
            operations[surfaceIdentity] = OperationState(
                token: operation,
                pending: []
            )
        }
    }

    func beginExternalOperation(
        for surfaceIdentity: UInt
    ) -> TerminalFindOperationToken {
        let operation = TerminalFindOperationToken()
        lock.lock()
        var state = operations[surfaceIdentity] ?? OperationState(
            token: nil,
            pending: []
        )
        // Keep the current generation for its in-flight reset pair, but let
        // the upstream search replace every operation still waiting behind it.
        state.token = state.token ?? state.pending.first?.token
        state.pending = [PendingOperation(token: operation)]
        state.receivedResetTotal = false
        operations[surfaceIdentity] = state
        lock.unlock()
        return operation
    }

    func operation(for surfaceIdentity: UInt) -> TerminalFindOperationToken? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = operations[surfaceIdentity] else { return nil }
        return state.pending.last?.token ?? state.token
    }

    func operation(
        for surfaceIdentity: UInt,
        callback: Callback
    ) -> TerminalFindOperationToken? {
        lock.lock()
        defer { lock.unlock() }
        guard var state = operations[surfaceIdentity] else { return nil }
        let operation = state.token ?? state.pending.first?.token

        // The search thread emits this pair before results for every new
        // needle. Advance one queued operation only after the full pair, so
        // callbacks already queued for the prior needle keep its token.
        switch callback {
        case .total(0):
            state.receivedResetTotal = true
        case .selected(-1) where state.receivedResetTotal:
            if !state.pending.isEmpty {
                let pending = state.pending.removeFirst()
                state.token = pending.token
            }
            state.receivedResetTotal = false
        default:
            break
        }
        operations[surfaceIdentity] = state
        return operation
    }

    func removeOperation(for surfaceIdentity: UInt) {
        lock.lock()
        operations.removeValue(forKey: surfaceIdentity)
        lock.unlock()
    }
}

extension TerminalSurfaceView {
    public func installLibghosttyFindController() {
        terminalFindController = TerminalFindController(
            isAvailable: true,
            failureHandler: { [weak self] message in
                self?.terminalOperationErrorMessage = message
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    if self?.terminalOperationErrorMessage == message {
                        self?.terminalOperationErrorMessage = nil
                    }
                }
            },
            sessionProvider: { [weak self] in
                guard let self else { return nil }
                return TerminalFindSession(
                    search: { [weak self] query, operation in
                        await MainActor.run {
                            guard let self else {
                                return .failure(.init(
                                    message: "The terminal could not start Find."
                                ))
                            }
                            self.prepareLibghosttyFindSearch(
                                operation
                            )
                            guard self.performBindingAction("search:\(query)")
                            else {
                                self.removeLibghosttyFindOperation()
                                return .failure(.init(
                                    message: "The terminal could not start Find."
                                ))
                            }
                            return .success(.awaitingCallback)
                        }
                    },
                    navigate: { [weak self] direction, operation in
                        await MainActor.run {
                            let action = direction == .next
                                ? "navigate_search:next"
                                : "navigate_search:previous"
                            guard let self else {
                                return .failure(.init(
                                    message: "The terminal could not navigate Find."
                                ))
                            }
                            self.prepareLibghosttyFindNavigation(operation)
                            guard self.performBindingAction(action)
                            else {
                                self.removeLibghosttyFindOperation()
                                return .failure(.init(
                                    message: "The terminal could not navigate Find."
                                ))
                            }
                            return .success(.awaitingCallback)
                        }
                    },
                    close: { [weak self] in
                        await MainActor.run {
                            guard let self else { return nil }
                            _ = self.performBindingAction("end_search")
                            return nil
                        }
                    }
                )
            }
        )
    }

    func publishLibghosttyFindTotal(
        _ total: Int,
        operation: TerminalFindOperationToken
    ) {
        libghosttyFindTotal = total
        terminalFindController.publishBackendResult(
            total: total,
            selected: libghosttyFindSelected,
            operation: operation
        )
    }

    func beginLibghosttyFind(
        _ query: String,
        operation: TerminalFindOperationToken
    ) {
        libghosttyFindTotal = -1
        libghosttyFindSelected = -1
        terminalFindController.backendDidOpen(
            query: query,
            operation: operation
        )
    }

    func publishLibghosttyFindSelected(
        _ selected: Int,
        operation: TerminalFindOperationToken
    ) {
        libghosttyFindSelected = selected
        terminalFindController.publishBackendResult(
            total: libghosttyFindTotal,
            selected: selected,
            operation: operation
        )
    }

    private func prepareLibghosttyFindSearch(
        _ operation: TerminalFindOperationToken
    ) {
        guard let surfaceIdentity else { return }
        LibghosttyFindOperationRegistry.shared.prepareSearch(
            operation,
            for: surfaceIdentity
        )
    }

    private func prepareLibghosttyFindNavigation(
        _ operation: TerminalFindOperationToken
    ) {
        guard let surfaceIdentity else { return }
        LibghosttyFindOperationRegistry.shared.prepareNavigation(
            operation,
            for: surfaceIdentity
        )
    }

    private func removeLibghosttyFindOperation() {
        guard let surfaceIdentity else { return }
        LibghosttyFindOperationRegistry.shared.removeOperation(
            for: surfaceIdentity
        )
    }
}
