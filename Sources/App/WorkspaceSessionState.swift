import Foundation

enum TmuxSessionThemeError: Error, Equatable, LocalizedError {
    case unavailable(session: String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(session):
            return "The theme cannot be applied to session “\(session)”"
                + " because its active tmux attachment is unavailable."
        }
    }
}

enum HerdrSessionPresentationError: Error, Equatable, LocalizedError {
    case unavailable
    case sessionExists(String)
    case sessionMissing(String)
    case sessionNotRunning(String)
    case sessionNotStopped(String)
    case operationPending(String)
    case routeChangedDuringValidation(String)
    case stateChangedDuringValidation(String)
    case stateValidationFailed(name: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Herdr is unavailable on this host."
        case let .sessionExists(name):
            "A Herdr session named “\(name)” already exists."
        case let .sessionMissing(name):
            "Herdr session “\(name)” no longer exists."
        case let .sessionNotRunning(name):
            "Herdr session “\(name)” is not running."
        case let .sessionNotStopped(name):
            "Herdr session “\(name)” is not stopped."
        case let .operationPending(name):
            "Another operation is already changing “\(name)”."
        case let .routeChangedDuringValidation(name):
            "The connection for the host containing “\(name)” changed while Ghosthub was checking it."
        case let .stateChangedDuringValidation(name):
            "Herdr session “\(name)” changed while Ghosthub was checking it. Try again."
        case let .stateValidationFailed(name, detail):
            "Ghosthub could not confirm the current state of Herdr session “\(name)”: \(detail)"
        }
    }
}

enum HerdrSessionLifecycleRequestError: Error, Equatable, LocalizedError {
    case hostChanged(String)

    var errorDescription: String? {
        switch self {
        case let .hostChanged(name):
            "The connection for the host containing “\(name)” changed."
        }
    }
}

enum ZellijSessionPresentationError: Error, Equatable, LocalizedError {
    case unavailable
    case sessionExists(String)
    case sessionMissing(String)
    case hostChanged(String)
    case operationPending(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Zellij is unavailable on this host."
        case let .sessionExists(name):
            "A Zellij session named “\(name)” already exists."
        case let .sessionMissing(name):
            "Zellij session “\(name)” no longer exists."
        case let .hostChanged(name):
            "The connection for the host containing “\(name)” changed."
        case let .operationPending(name):
            "Another operation is already changing “\(name)”."
        }
    }
}

struct WorkspaceInventoryRefreshProgress: Equatable {
    var kwtCompleted = false
    var tmuxCompleted = false
    var herdrCompleted = false
    var zellijCompleted = false
}

enum NativeSessionRecoveryState: Equatable {
    case reconnecting(message: String)
    case needsAttention(message: String, canReviewConnection: Bool)

    var isReconnecting: Bool {
        if case .reconnecting = self {
            return true
        }
        return false
    }

    var allowsReconnectNow: Bool {
        switch self {
        case .reconnecting:
            true
        case let .needsAttention(_, canReviewConnection):
            !canReviewConnection
        }
    }
}
