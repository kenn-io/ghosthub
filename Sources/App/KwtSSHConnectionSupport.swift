import Foundation
import GhosthubSettings
import GhosthubTransport

enum SSHHostTrustRequirement: Equatable, Sendable {
    case none
    case confirmation(SSHHostKeyConfirmation)
    case authentication
}

struct SSHAuthenticationPrompt: Equatable, Sendable {
    let id: String
    let message: String
}

enum SSHAuthenticationSessionState: Equatable, Sendable {
    case starting
    case prompt(SSHAuthenticationPrompt)
    case verifying
    case connected
    case configurationChanged
    case failed(String)
}
