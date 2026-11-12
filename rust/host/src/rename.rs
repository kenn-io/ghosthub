use session::{DiscoveredSession, SessionName};

pub(crate) fn arguments(
    session: &DiscoveredSession,
    name: &SessionName,
    marker: &str,
) -> Vec<String> {
    let target = format!("={}:", session.name());
    vec![
        "if-shell".into(),
        "-F".into(),
        "-t".into(),
        target.clone(),
        crate::local::tmux_identity_condition(session.identity()),
        format!(
            "rename-session -t {} -- {}",
            crate::remote::shell_quoted_argument(&target),
            crate::remote::shell_quoted_argument(name.as_str())
        ),
        format!("display-message -p {marker}"),
    ]
}
