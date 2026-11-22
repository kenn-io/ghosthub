import Foundation

/// A tmux session kwt saved from a server that has since stopped, such as
/// after a reboot. `kwt session snapshot --json` lists these; `kwt session
/// restore` rebuilds them and resumes their Claude Code, Codex, and agy panes.
public struct SavedTmuxSession: Decodable, Equatable, Sendable, Identifiable {
    public struct Socket: Decodable, Equatable, Sendable {
        public var path: String
        /// The name given to `tmux -L`, or nil for a socket kwt found by path.
        public var name: String?

        public init(path: String, name: String? = nil) {
            self.path = path
            self.name = name
        }
    }

    public var id: String
    public var socket: Socket
    public var session: String
    public var windows: Int
    public var panes: Int
    public var agents: [String]
    /// A live session already has this name, so restore will skip it.
    public var nameTaken: Bool
    /// A kwt worktree or directory workspace session. Opening its workspace
    /// restores it, so the sidebar shows it on that workspace's row.
    public var worktree: Bool
    /// Unix milliseconds; among saved sessions with one name, kwt restores
    /// the newest.
    public var savedAt: Int64
    /// Ghosthub is restoring this session now. Never decoded.
    public var isRestoring = false

    public init(
        id: String,
        socket: Socket,
        session: String,
        windows: Int = 1,
        panes: Int = 1,
        agents: [String] = [],
        nameTaken: Bool = false,
        worktree: Bool = false,
        savedAt: Int64 = 0
    ) {
        self.id = id
        self.socket = socket
        self.session = session
        self.windows = windows
        self.panes = panes
        self.agents = agents
        self.nameTaken = nameTaken
        self.worktree = worktree
        self.savedAt = savedAt
    }

    /// Ghosthub lists and attaches tmux sessions on the default server and
    /// on kwt's server only, so it offers to restore only those.
    public var isOnGhosthubServer: Bool {
        socket.name == "default" || socket.name == "kwt"
    }

    /// The socket name Ghosthub's tmux selections use: nil for the default
    /// server.
    public var tmuxSocketName: String? {
        socket.name == "default" ? nil : socket.name
    }

    private enum CodingKeys: String, CodingKey {
        case id, socket, session, windows, panes, agents
        case nameTaken = "name_taken"
        case worktree
        case savedAt = "saved_at"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        socket = try container.decode(Socket.self, forKey: .socket)
        session = try container.decode(String.self, forKey: .session)
        windows = try container.decodeIfPresent(Int.self, forKey: .windows) ?? 0
        panes = try container.decodeIfPresent(Int.self, forKey: .panes) ?? 0
        agents = try container.decodeIfPresent([String].self, forKey: .agents) ?? []
        nameTaken = try container.decodeIfPresent(Bool.self, forKey: .nameTaken) ?? false
        worktree = try container.decodeIfPresent(Bool.self, forKey: .worktree) ?? false
        savedAt = try container.decodeIfPresent(Int64.self, forKey: .savedAt) ?? 0
    }
}

/// What `kwt session restore --json` did with each saved session.
public struct TmuxRestoreReport: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public var id: String
        public var session: String?
        public var outcome: String
        public var reason: String?
        public var notes: [String]?
        public var panes: [Pane]?
    }

    public struct Pane: Decodable, Equatable, Sendable {
        public var window: Int
        public var pane: Int
        public var agent: String?
        public var status: String
        public var note: String?
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// One line per session that did not come back cleanly and per pane
    /// note, in kwt's wording. Empty when every session was restored.
    public var problems: [String] {
        entries.flatMap { entry -> [String] in
            let name = entry.session ?? entry.id
            var lines: [String] = []
            if entry.outcome != "restored" {
                var line = "\(name): \(entry.outcome)"
                if let reason = entry.reason, !reason.isEmpty {
                    line += " (\(reason))"
                }
                lines.append(line)
            }
            lines += (entry.notes ?? []).map { "\(name): \($0)" }
            for pane in entry.panes ?? []
                where pane.note != nil || pane.status == "failed" || pane.status == "waiting" {
                var line = "\(name), window \(pane.window) pane \(pane.pane): "
                    + [pane.agent, pane.status == "none" ? "not started" : pane.status]
                    .compactMap { $0 }.joined(separator: " ")
                if let note = pane.note {
                    line += " (\(note))"
                }
                lines.append(line)
            }
            return lines
        }
    }
}
