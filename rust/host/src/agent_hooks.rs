use serde::Deserialize;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgentHookAction {
    Status,
    Install,
}

impl AgentHookAction {
    pub(crate) const fn command(self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::Install => "install",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct AgentHookStatus {
    pub agent: String,
    pub display_name: String,
    pub available: bool,
    pub installed: bool,
    pub current: bool,
}

pub(crate) fn parse(bytes: &[u8]) -> Result<Vec<AgentHookStatus>, String> {
    #[derive(Deserialize)]
    struct Response {
        agents: Vec<AgentHookStatus>,
    }
    serde_json::from_slice::<Response>(bytes)
        .map(|response| response.agents)
        .map_err(|error| format!("Could not read agent hook status: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statuses_distinguish_missing_current_and_outdated_hooks() {
        let rows = parse(br#"{"agents":[
            {"agent":"claude","display_name":"Claude Code","available":true,"installed":false,"current":false},
            {"agent":"codex","display_name":"Codex","available":true,"installed":true,"current":true},
            {"agent":"gemini","display_name":"Gemini CLI","available":true,"installed":true,"current":false},
            {"agent":"cursor","display_name":"Cursor","available":false,"installed":false,"current":false}
        ]}"#).unwrap();
        assert_eq!(
            rows.iter()
                .filter(|row| row.available && !row.current)
                .map(|row| row.agent.as_str())
                .collect::<Vec<_>>(),
            ["claude", "gemini"]
        );
        assert_eq!(rows[0].display_name, "Claude Code");
        for invalid in [
            b"{}".as_slice(),
            b"{\"agents\":[{\"agent\":\"codex\"}]}",
            b"not json",
        ] {
            assert!(parse(invalid).is_err());
        }
    }
}
