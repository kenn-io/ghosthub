@preconcurrency import Combine
import Foundation
import GhosthubTmux
import GhosthubTransport

/// Every scene keys its tmux presentations by session name, so a rename made
/// in one window is published to all of them, including the one that made it.
@MainActor
final class TmuxSessionRenameCoordinator {
    struct Rename: Equatable, Sendable {
        let hostID: UUID
        let host: CommandHost
        let oldName: String
        let newName: String
        let identity: TmuxSessionIdentity
    }

    static let shared = TmuxSessionRenameCoordinator()

    private let subject = PassthroughSubject<Rename, Never>()

    var renames: AnyPublisher<Rename, Never> {
        subject.eraseToAnyPublisher()
    }

    func didRename(_ rename: Rename) {
        subject.send(rename)
    }
}
