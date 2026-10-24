@preconcurrency import Combine
import Foundation
import GhosthubTmux
import GhosthubTransport

/// Every scene keys its tmux presentations by session name. Renames go into
/// a log, kept as the latest name of each session, so a scene that cannot
/// move a client when a rename lands can still apply it later.
@MainActor
final class TmuxSessionRenameCoordinator {
    struct Rename: Equatable, Sendable {
        let hostID: UUID
        let host: CommandHost
        let oldName: String
        let newName: String
        let identity: TmuxSessionIdentity
    }

    struct Entry: Equatable, Sendable {
        let sequence: UInt64
        let rename: Rename
    }

    private struct SessionKey: Hashable {
        let host: CommandHost
        let identity: TmuxSessionIdentity
    }

    static let shared = TmuxSessionRenameCoordinator()

    /// The sequence of the newest entry, or zero before any rename.
    private(set) var sequence: UInt64 = 0
    private var latest: [SessionKey: Entry] = [:]
    private let subject = PassthroughSubject<Entry, Never>()

    var renames: AnyPublisher<Entry, Never> {
        subject.eraseToAnyPublisher()
    }

    func didRename(_ rename: Rename) {
        sequence &+= 1
        let entry = Entry(sequence: sequence, rename: rename)
        latest[SessionKey(host: rename.host, identity: rename.identity)] = entry
        subject.send(entry)
    }

    func latestRename(
        of identity: TmuxSessionIdentity,
        on host: CommandHost
    ) -> Entry? {
        latest[SessionKey(host: host, identity: identity)]
    }
}
