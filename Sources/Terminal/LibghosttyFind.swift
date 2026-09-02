import GhosthubTerminalSupport

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
                    search: { [weak self] query in
                        await MainActor.run {
                            guard let self,
                                  self.performBindingAction("search:\(query)")
                            else {
                                return .failure(.init(
                                    message: "The terminal could not start Find."
                                ))
                            }
                            return .success(.awaitingCallback)
                        }
                    },
                    navigate: { [weak self] direction in
                        await MainActor.run {
                            let action = direction == .next
                                ? "navigate_search:next"
                                : "navigate_search:previous"
                            guard let self,
                                  self.performBindingAction(action)
                            else {
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

    func publishLibghosttyFindTotal(_ total: Int) {
        libghosttyFindTotal = total
        terminalFindController.publishBackendResult(
            total: total,
            selected: libghosttyFindSelected
        )
    }

    func beginLibghosttyFind(_ query: String) {
        libghosttyFindTotal = -1
        libghosttyFindSelected = -1
        terminalFindController.backendDidOpen(query: query)
    }

    func publishLibghosttyFindSelected(_ selected: Int) {
        libghosttyFindSelected = selected
        terminalFindController.publishBackendResult(
            total: libghosttyFindTotal,
            selected: selected
        )
    }
}
