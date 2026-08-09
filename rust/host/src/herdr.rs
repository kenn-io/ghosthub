use serde::Deserialize;
use session::{HerdrSessionRecord, HerdrSessionState};

pub(crate) const PATH_MARKER: &str = "GHOSTHUB_HERDR_PATH";

pub(crate) const ACCOUNT_LOGIN_HANDOFF: &str = concat!(
    "ghosthub_account_shell=$(/usr/bin/getent passwd \"$(/usr/bin/id -u)\" ",
    "| /usr/bin/cut -d: -f7); ",
    "[ -n \"$ghosthub_account_shell\" ] && [ -x \"$ghosthub_account_shell\" ] || exit 127; ",
    "exec \"$ghosthub_account_shell\" -lc \"$1\""
);

pub(crate) const RESOLVE_SCRIPT: &str = concat!(
    "unset HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH ",
    "HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_BIN_PATH ",
    "HERDR_ACTIVE_WORKSPACE_ID HERDR_ACTIVE_TAB_ID HERDR_ACTIVE_PANE_ID ",
    "HERDR_ACTIVE_PANE_CWD; ",
    "ghosthub_herdr_path=$(command -v herdr) || exit 127; ",
    "[ -n \"$ghosthub_herdr_path\" ] || exit 127; ",
    "case \"$ghosthub_herdr_path\" in /*) ;; *) exit 127 ;; esac; ",
    "[ -x \"$ghosthub_herdr_path\" ] || exit 127; ",
    "printf '%s\\n%s\\n' 'GHOSTHUB_HERDR_PATH' \"$ghosthub_herdr_path\""
);

pub(crate) const CONTROL_VARIABLES: [&str; 12] = [
    "HERDR_ENV",
    "HERDR_SESSION",
    "HERDR_SOCKET_PATH",
    "HERDR_CLIENT_SOCKET_PATH",
    "HERDR_PANE_ID",
    "HERDR_TAB_ID",
    "HERDR_WORKSPACE_ID",
    "HERDR_BIN_PATH",
    "HERDR_ACTIVE_WORKSPACE_ID",
    "HERDR_ACTIVE_TAB_ID",
    "HERDR_ACTIVE_PANE_ID",
    "HERDR_ACTIVE_PANE_CWD",
];

pub(crate) enum ExecutableProbe {
    Available(String),
    Unavailable,
}

pub(crate) fn parse_executable(status: i32, stdout: &[u8]) -> Result<ExecutableProbe, String> {
    if status == 127 {
        return Ok(ExecutableProbe::Unavailable);
    }
    if status != 0 {
        return Err(format!(
            "Herdr executable probe exited with status {status}"
        ));
    }
    let stdout = std::str::from_utf8(stdout)
        .map_err(|_| "Herdr executable probe output is not UTF-8".to_owned())?;
    let mut lines = stdout.lines();
    let mut resolved = None;
    while let Some(line) = lines.next() {
        if line == PATH_MARKER {
            resolved = lines.next();
        }
    }
    let Some(path) = resolved.map(str::trim).filter(|path| path.starts_with('/')) else {
        return Ok(ExecutableProbe::Unavailable);
    };
    Ok(ExecutableProbe::Available(path.to_owned()))
}

pub(crate) fn parse_inventory(bytes: &[u8]) -> Result<Vec<HerdrSessionRecord>, String> {
    let envelope: SessionEnvelope = serde_json::from_slice(bytes)
        .map_err(|_| "Herdr returned malformed session inventory JSON".to_owned())?;
    Ok(envelope
        .sessions
        .into_iter()
        .map(|session| {
            HerdrSessionRecord::new(
                session.name,
                session.is_default,
                if session.running {
                    HerdrSessionState::Running
                } else {
                    HerdrSessionState::Stopped
                },
                session.directory,
                session.socket,
            )
        })
        .collect())
}

#[derive(Deserialize)]
struct SessionEnvelope {
    sessions: Vec<Session>,
}

#[derive(Deserialize)]
struct Session {
    name: String,
    #[serde(rename = "default")]
    is_default: bool,
    running: bool,
    #[serde(rename = "session_dir")]
    directory: String,
    #[serde(rename = "socket_path")]
    socket: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn executable_probe_uses_the_last_marker_and_requires_an_absolute_path() {
        assert!(matches!(
            parse_executable(0, b"banner\nGHOSTHUB_HERDR_PATH\n/usr/local/bin/herdr\n"),
            Ok(ExecutableProbe::Available(path)) if path == "/usr/local/bin/herdr"
        ));
        assert!(matches!(
            parse_executable(0, b"GHOSTHUB_HERDR_PATH\nrelative/herdr\n"),
            Ok(ExecutableProbe::Unavailable)
        ));
        assert!(matches!(
            parse_executable(127, b""),
            Ok(ExecutableProbe::Unavailable)
        ));
    }

    #[test]
    fn inventory_preserves_running_stopped_and_location_fields() {
        let sessions = parse_inventory(
            br#"{"sessions":[
                {"name":"default","default":true,"running":true,"session_dir":"/tmp/default","socket_path":"/tmp/default/herdr.sock"},
                {"name":"review","default":false,"running":false,"session_dir":"/tmp/review","socket_path":"/tmp/review/herdr.sock","future":"ignored"}
            ]}"#,
        )
        .expect("valid Herdr inventory");

        assert_eq!(sessions.len(), 2);
        assert_eq!(sessions[0].state(), HerdrSessionState::Running);
        assert!(sessions[0].is_default());
        assert_eq!(sessions[1].state(), HerdrSessionState::Stopped);
        assert_eq!(sessions[1].session_directory(), "/tmp/review");
        assert_eq!(sessions[1].socket_path(), "/tmp/review/herdr.sock");
    }
}
