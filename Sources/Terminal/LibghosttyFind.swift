import Foundation
import GhosthubTerminalSupport

final class LibghosttyFindOperationRegistry: @unchecked Sendable {
    static let shared = LibghosttyFindOperationRegistry()

    private let lock = NSLock()
    private var operations: [UInt: TerminalFindOperationToken] = [:]

    func prepare(
        _ operation: TerminalFindOperationToken,
        for surfaceIdentity: UInt
    ) {
        lock.lock()
        operations[surfaceIdentity] = operation
        lock.unlock()
    }

    func beginExternalOperation(
        for surfaceIdentity: UInt
    ) -> TerminalFindOperationToken {
        let operation = TerminalFindOperationToken()
        prepare(operation, for: surfaceIdentity)
        return operation
    }

    func operation(for surfaceIdentity: UInt) -> TerminalFindOperationToken? {
        lock.lock()
        defer { lock.unlock() }
        return operations[surfaceIdentity]
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
                            self.prepareLibghosttyFindOperation(operation)
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
                            self.prepareLibghosttyFindOperation(operation)
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

    private func prepareLibghosttyFindOperation(
        _ operation: TerminalFindOperationToken
    ) {
        guard let surfaceIdentity else { return }
        LibghosttyFindOperationRegistry.shared.prepare(
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
