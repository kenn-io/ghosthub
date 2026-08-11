use session::ZellijSessionRecord;

pub(crate) const PATH_MARKER: &str = "GHOSTHUB_ZELLIJ_PATH";
pub(crate) const CONTROL_VARIABLES: [&str; 3] = ["ZELLIJ", "ZELLIJ_PANE_ID", "ZELLIJ_SESSION_NAME"];

pub(crate) const RESOLVE_SCRIPT: &str = concat!(
    "unset ZELLIJ ZELLIJ_PANE_ID ZELLIJ_SESSION_NAME; ",
    "ghosthub_zellij_path=$(command -v zellij) || exit 127; ",
    "[ -n \"$ghosthub_zellij_path\" ] || exit 127; ",
    "case \"$ghosthub_zellij_path\" in /*) ;; *) exit 127 ;; esac; ",
    "[ -x \"$ghosthub_zellij_path\" ] || exit 127; ",
    "printf '%s\\n%s\\n' 'GHOSTHUB_ZELLIJ_PATH' \"$ghosthub_zellij_path\""
);

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
            "Zellij executable probe exited with status {status}"
        ));
    }
    let stdout = std::str::from_utf8(stdout)
        .map_err(|_| "Zellij executable probe output is not UTF-8".to_owned())?;
    let mut lines = stdout.lines();
    let mut resolved = None;
    while let Some(line) = lines.next() {
        if line == PATH_MARKER {
            resolved = lines.next();
        }
    }
    let path = resolved
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .ok_or_else(|| "Zellij executable probe omitted its resolved path".to_owned())?;
    if !path.starts_with('/') {
        return Err(format!(
            "Zellij executable probe returned a non-absolute path: {path}"
        ));
    }
    Ok(ExecutableProbe::Available(path.to_owned()))
}

pub(crate) fn parse_inventory(
    status: i32,
    stdout: &[u8],
    stderr: &[u8],
) -> Result<Vec<ZellijSessionRecord>, String> {
    if status != 0 {
        let detail = String::from_utf8_lossy(stderr).trim().to_owned();
        if status == 1 && detail == "No active zellij sessions found." {
            return Ok(Vec::new());
        }
        return Err(if detail.is_empty() {
            format!("Zellij session inventory exited with status {status}")
        } else {
            format!("Zellij session inventory exited with status {status}: {detail}")
        });
    }

    let stdout = std::str::from_utf8(stdout)
        .map_err(|_| "Zellij session inventory is not UTF-8".to_owned())?;
    stdout
        .lines()
        .filter(|line| !line.is_empty())
        .filter_map(|line| {
            let metadata = line.rfind(" [Created ");
            match metadata {
                Some(index) if line[index..].contains("(EXITED - attach to resurrect)") => None,
                Some(index) => Some(Ok(ZellijSessionRecord::discovered(&line[..index]))),
                None => Some(Err(format!(
                    "Zellij returned an unrecognized session entry: {line}"
                ))),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inventory_preserves_active_names_and_ignores_resurrectable_sessions() {
        let sessions = parse_inventory(
            0,
            b"work [Created 2m ago] (CURRENT)\nold [Created 3h ago] (EXITED - attach to resurrect)\nname with spaces [Created now]\n",
            b"",
        )
        .expect("valid inventory");
        assert_eq!(
            sessions
                .iter()
                .map(ZellijSessionRecord::name)
                .collect::<Vec<_>>(),
            ["work", "name with spaces"]
        );
    }

    #[test]
    fn no_active_sessions_is_available_empty() {
        assert_eq!(
            parse_inventory(1, b"", b"No active zellij sessions found.").expect("empty inventory"),
            Vec::<ZellijSessionRecord>::new()
        );
    }

    #[test]
    fn malformed_inventory_is_rejected() {
        assert!(parse_inventory(0, b"not an inventory row\n", b"").is_err());
    }

    #[test]
    fn only_status_127_means_zellij_is_unavailable() {
        assert!(matches!(
            parse_executable(127, b""),
            Ok(ExecutableProbe::Unavailable)
        ));
        assert!(parse_executable(0, b"").is_err());
        assert!(parse_executable(0, b"GHOSTHUB_ZELLIJ_PATH\n").is_err());
        assert!(parse_executable(0, b"GHOSTHUB_ZELLIJ_PATH\nrelative/zellij\n").is_err());
    }
}
