//! Live pane state written by `kwt agent-hook`. Completed turns need separate
//! acknowledgement tracking and are deliberately excluded from live activity.

use crate::DiscoveredSession;

pub const AGENT_PANE_FORMAT: &str =
    "#{pid}|#{session_id}|#{session_created}|#{pane_id}|#{@kwt_agent}";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentState {
    Approval,
    Input,
    Working,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AgentActivity {
    state: AgentState,
    stamp: u64,
    agent: String,
}

impl AgentActivity {
    /// Parse the public KWT pane option. Absent or malformed hooks are silent.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        let mut fields = value.split_whitespace();
        let state = match fields.next()? {
            "approval" => AgentState::Approval,
            "input" => AgentState::Input,
            "working" => AgentState::Working,
            _ => return None,
        };
        let stamp = fields.next()?.parse().ok().filter(|stamp| *stamp > 0)?;
        let agent = fields.next()?.to_owned();
        if fields.next().is_some() || agent.chars().any(char::is_control) {
            return None;
        }
        Some(Self {
            state,
            stamp,
            agent,
        })
    }

    #[must_use]
    pub const fn state(&self) -> AgentState {
        self.state
    }

    #[must_use]
    pub const fn title(&self) -> &'static str {
        match self.state {
            AgentState::Approval => "Approval",
            AgentState::Input => "Input",
            AgentState::Working => "Working",
        }
    }

    #[must_use]
    pub fn label(&self) -> String {
        let agent = match self.agent.as_str() {
            "claude" => "Claude".to_owned(),
            "codex" => "Codex".to_owned(),
            "copilot" => "Copilot".to_owned(),
            "cursor" => "Cursor".to_owned(),
            "droid" => "Droid".to_owned(),
            "gemini" => "Gemini".to_owned(),
            "hermes" => "Hermes".to_owned(),
            "qwen" => "Qwen".to_owned(),
            "opencode" => "OpenCode".to_owned(),
            other => {
                let mut characters = other.chars();
                characters.next().map_or_else(String::new, |first| {
                    first.to_uppercase().collect::<String>() + characters.as_str()
                })
            }
        };
        match self.state {
            AgentState::Approval => format!("{agent} needs approval"),
            AgentState::Input => format!("{agent} is waiting for input"),
            AgentState::Working => format!("{agent} is working"),
        }
    }

    const fn priority(&self) -> u8 {
        match self.state {
            AgentState::Approval => 0,
            AgentState::Input => 1,
            AgentState::Working => 2,
        }
    }
}

/// Enrich fresh inventory only when a pane's full session identity matches.
/// A failed or malformed optional probe must never hide ordinary sessions.
pub fn apply_agent_activity(sessions: &mut [DiscoveredSession], output: &[u8]) {
    for session in sessions.iter_mut() {
        session.agent_activity = None;
    }
    let Ok(output) = std::str::from_utf8(output) else {
        return;
    };
    for line in output.lines() {
        let fields: Vec<_> = line.split('|').collect();
        let [pid, session_id, created, pane_id, value] = fields.as_slice() else {
            continue;
        };
        let (Ok(pid), Ok(created)) = (pid.parse::<u32>(), created.parse::<u64>()) else {
            continue;
        };
        if !pane_id
            .strip_prefix('%')
            .is_some_and(|id| !id.is_empty() && id.bytes().all(|byte| byte.is_ascii_digit()))
        {
            continue;
        }
        let Some(activity) = AgentActivity::parse(value) else {
            continue;
        };
        let Some(session) = sessions.iter_mut().find(|session| {
            let identity = session.identity();
            identity.server_pid() == pid
                && identity.session_id() == *session_id
                && identity.created_at() == created
        }) else {
            continue;
        };
        if session.agent_activity.as_ref().is_none_or(|previous| {
            activity.priority() < previous.priority()
                || (activity.priority() == previous.priority() && activity.stamp > previous.stamp)
        }) {
            session.agent_activity = Some(activity);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SessionIdentity;

    #[test]
    fn inventory_joins_exact_identities_and_prioritizes_waiting_panes() {
        let mut sessions = vec![
            DiscoveredSession::new("review", SessionIdentity::new(20, "$1", 30), 0),
            DiscoveredSession::new("build", SessionIdentity::new(20, "$2", 30), 0),
            DiscoveredSession::new("done", SessionIdentity::new(20, "$3", 30), 0),
        ];
        apply_agent_activity(&mut sessions, b"20|$1|30|%0|working 100 claude\n20|$1|30|%1|input 90 gemini\n20|$1|30|%2|approval 80 codex\n20|$1|30|%3|approval 85 claude\n20|$2|30|%4|working 101 codex\n20|$3|30|%5|done 102 codex\n21|$2|30|%6|approval 200 claude\n20|$2|31|%6|approval 200 claude\n20|$99|30|%6|approval 200 claude\n20|$2|30|%7|input 0 codex\n20|$2|30|%8|input oops codex\n20|$2|30|bad|input 200 codex\n20|$2|30|%9|input 200 codex extra\n");
        assert_eq!(
            sessions[0].agent_activity().unwrap().label(),
            "Claude needs approval"
        );
        assert_eq!(
            sessions[1].agent_activity().unwrap().label(),
            "Codex is working"
        );
        assert!(sessions[2].agent_activity().is_none());
        apply_agent_activity(&mut sessions, b"20|$1|30|%0|done 110 codex\n");
        assert!(
            sessions
                .iter()
                .all(|session| session.agent_activity().is_none())
        );
    }
}
