import Foundation

/// Lifecycle state an agent hook recorded on its tmux pane. `kwt agent-hook`
/// writes the pane option `@ghosthub_agent` as "<state> <unix-seconds>
/// <agent>"; see `kwt agent-hook --help`.
public enum AgentHookState: String, Codable, Sendable {
    case working
    case approval
    case input
    case done
}

/// One pane's recorded agent state. The stamp uses the host's clock, so it
/// is only compared with other stamps from the same host.
public struct TmuxPaneAgentState: Codable, Equatable, Sendable {
    public var paneID: String
    public var state: AgentHookState
    public var stamp: Int
    public var agent: String

    public init(paneID: String, state: AgentHookState, stamp: Int, agent: String) {
        self.paneID = paneID
        self.state = state
        self.stamp = stamp
        self.agent = agent
    }

    /// Parses a `@ghosthub_agent` option value; returns nil for anything
    /// the hook would not have written.
    public init?(paneID: String, optionValue: String) {
        let fields = optionValue.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3,
              let state = AgentHookState(rawValue: String(fields[0])),
              let stamp = Int(fields[1]), stamp > 0
        else { return nil }
        self.init(paneID: paneID, state: state, stamp: stamp, agent: String(fields[2]))
    }
}

/// Why a session's row shows the attention dot.
public enum AgentAttention: Equatable, Sendable {
    case approval(agent: String)
    case input(agent: String)
    case finished(agent: String)

    public var agent: String {
        switch self {
        case let .approval(agent), let .input(agent), let .finished(agent):
            agent
        }
    }

    /// Short description for tooltips and accessibility.
    public var label: String {
        let name = Self.displayName(agent)
        return switch self {
        case .approval: "\(name) needs approval"
        case .input: "\(name) is waiting for input"
        case .finished: "\(name) finished"
        }
    }

    static func displayName(_ agent: String) -> String {
        switch agent {
        case "claude": "Claude"
        case "codex": "Codex"
        case "copilot": "Copilot"
        case "cursor": "Cursor"
        case "droid": "Droid"
        case "gemini": "Gemini"
        case "hermes": "Hermes"
        case "qwen": "Qwen"
        case "opencode": "OpenCode"
        default: agent.isEmpty ? "Agent" : agent.prefix(1).uppercased() + String(agent.dropFirst())
        }
    }
}

public extension TmuxSessionSummary {
    /// Newest finished-turn stamp across the session's panes.
    var latestAgentDoneStamp: Int? {
        agentPanes.filter { $0.state == .done }.map(\.stamp).max()
    }

    /// The attention a session needs. A pending approval or question always
    /// shows; a finished turn shows until a stamp at least as new has been
    /// acknowledged by viewing the session.
    func agentAttention(acknowledgedDoneStamp: Int?) -> AgentAttention? {
        if let pane = newest(.approval) {
            return .approval(agent: pane.agent)
        }
        if let pane = newest(.input) {
            return .input(agent: pane.agent)
        }
        if let pane = newest(.done), pane.stamp > (acknowledgedDoneStamp ?? 0) {
            return .finished(agent: pane.agent)
        }
        return nil
    }

    /// Identity used to remember acknowledgements. A same-named replacement
    /// session gets a new key, so its finished turns are not hidden.
    func agentAttentionKey(hostID: UUID) -> String {
        [
            hostID.uuidString,
            socketName ?? "default",
            name,
            serverPID ?? "",
            sessionID ?? "",
            createdAt ?? "",
        ].joined(separator: "|")
    }

    private func newest(_ state: AgentHookState) -> TmuxPaneAgentState? {
        agentPanes.filter { $0.state == state }.max { $0.stamp < $1.stamp }
    }
}
