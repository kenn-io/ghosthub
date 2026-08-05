//! Isolated psmux capability-probe command planning.

use std::{fmt, io, process::Command};

use crate::ProbeObservation;

const PREFIX: &str = "ghosthub-test-";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProbeNamespace(String);

impl ProbeNamespace {
    /// Construct a namespace which cannot address psmux's default server.
    ///
    /// # Errors
    ///
    /// Returns an error unless the name has the reserved test prefix, a
    /// non-empty suffix, and only ASCII alphanumeric or hyphen characters.
    pub fn new(name: &str) -> Result<Self, InvalidNamespace> {
        let suffix = name.strip_prefix(PREFIX).unwrap_or_default();
        if suffix.is_empty()
            || !suffix
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return Err(InvalidNamespace);
        }
        Ok(Self(name.to_owned()))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct InvalidNamespace;

impl fmt::Display for InvalidNamespace {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("psmux probe namespace must use the ghosthub-test- prefix")
    }
}

impl std::error::Error for InvalidNamespace {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProbeCommand {
    name: &'static str,
    arguments: Vec<String>,
}

impl ProbeCommand {
    #[must_use]
    pub const fn name(&self) -> &str {
        self.name
    }

    #[must_use]
    pub fn arguments(&self) -> &[String] {
        &self.arguments
    }
}

#[must_use]
pub fn psmux_probe_plan(namespace: &ProbeNamespace) -> Vec<ProbeCommand> {
    [
        (
            "atomic-create-or-attach",
            &[
                "new-session",
                "-A",
                "-d",
                "-s",
                "ghosthub",
                "-e",
                "GHOSTHUB_PROBE=present",
            ][..],
        ),
        (
            "prefix-collision",
            &["new-session", "-d", "-s", "ghosthub-old"][..],
        ),
        ("exact-existing", &["has-session", "-t", "=ghosthub"][..]),
        ("exact-prefix-miss", &["has-session", "-t", "=ghost"][..]),
        (
            "new-session-environment",
            &["show-environment", "-t", "=ghosthub", "GHOSTHUB_PROBE"][..],
        ),
        (
            "stable-session-identity",
            &["display-message", "-p", "-t", "=ghosthub", "#{session_id}"][..],
        ),
        (
            "server-instance-identity",
            &["display-message", "-p", "-t", "=ghosthub", "#{pid}"][..],
        ),
        (
            "attach-preserve-environment",
            &["attach-session", "-E", "-t", "=ghosthub"][..],
        ),
        (
            "rename",
            &["rename-session", "-t", "=ghosthub", "ghosthub-renamed"][..],
        ),
        (
            "exact-kill",
            &["kill-session", "-t", "=ghosthub-renamed"][..],
        ),
        (
            "collision-survives",
            &["has-session", "-t", "=ghosthub-old"][..],
        ),
        ("stop-server", &["kill-server"][..]),
        (
            "restart-server",
            &["new-session", "-d", "-s", "server-restart"][..],
        ),
        (
            "restarted-server-identity",
            &["display-message", "-p", "-t", "=server-restart", "#{pid}"][..],
        ),
    ]
    .into_iter()
    .map(|(name, command)| ProbeCommand {
        name,
        arguments: ["-f", "NUL", "-L", namespace.as_str()]
            .into_iter()
            .chain(command.iter().copied())
            .map(str::to_owned)
            .collect(),
    })
    .collect()
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProbeReport {
    version_output: String,
    observations: Vec<ProbeObservation>,
}

impl ProbeReport {
    #[must_use]
    pub fn version_output(&self) -> &str {
        &self.version_output
    }

    #[must_use]
    pub fn observations(&self) -> &[ProbeObservation] {
        &self.observations
    }
}

/// Run non-interactive psmux capability probes in an isolated namespace.
///
/// Attachment is deliberately reported as unproven until the `ConPTY` harness
/// supplies a genuine terminal client; redirected psmux clients are not a
/// valid attachment probe.
///
/// # Errors
///
/// Returns an I/O error when psmux cannot be spawned. Command failures are
/// retained as negative observations in the report.
#[allow(
    clippy::too_many_lines,
    reason = "the linear probe transcript is easier to audit when command order stays together"
)]
pub fn probe_psmux(executable: &str, namespace: &ProbeNamespace) -> io::Result<ProbeReport> {
    let _cleanup = CleanupGuard {
        executable,
        namespace,
    };
    let version = Command::new(executable).arg("-V").output()?;
    let version_output = combined_output(&version.stdout, &version.stderr);

    let create = run(
        executable,
        namespace,
        &[
            "new-session",
            "-A",
            "-d",
            "-s",
            "ghosthub",
            "-e",
            "GHOSTHUB_PROBE=present",
        ],
    )?;
    let create_again = run(
        executable,
        namespace,
        &["new-session", "-A", "-d", "-s", "ghosthub"],
    )?;
    let collision = run(
        executable,
        namespace,
        &["new-session", "-d", "-s", "ghosthub-old"],
    )?;
    let exact_existing = run(executable, namespace, &["has-session", "-t", "=ghosthub"])?;
    let exact_prefix_miss = run(executable, namespace, &["has-session", "-t", "=ghost"])?;
    let environment = run(
        executable,
        namespace,
        &["show-environment", "-t", "=ghosthub", "GHOSTHUB_PROBE"],
    )?;
    let session_id = run(
        executable,
        namespace,
        &["display-message", "-p", "-t", "=ghosthub", "#{session_id}"],
    )?;
    let server_pid = run(
        executable,
        namespace,
        &["display-message", "-p", "-t", "=ghosthub", "#{pid}"],
    )?;
    let rename = run(
        executable,
        namespace,
        &["rename-session", "-t", "=ghosthub", "ghosthub-renamed"],
    )?;
    let renamed_id = run(
        executable,
        namespace,
        &[
            "display-message",
            "-p",
            "-t",
            "=ghosthub-renamed",
            "#{session_id}",
        ],
    )?;
    let exact_kill = run(
        executable,
        namespace,
        &["kill-session", "-t", "=ghosthub-renamed"],
    )?;
    let collision_survives = run(
        executable,
        namespace,
        &["has-session", "-t", "=ghosthub-old"],
    )?;
    let killed_absent = run(
        executable,
        namespace,
        &["has-session", "-t", "=ghosthub-renamed"],
    )?;

    let stop_server = run(executable, namespace, &["kill-server"])?;
    let restart = run(
        executable,
        namespace,
        &["new-session", "-d", "-s", "server-restart"],
    )?;
    let restarted_pid = run(
        executable,
        namespace,
        &["display-message", "-p", "-t", "=server-restart", "#{pid}"],
    )?;

    let atomic = create.success() && create_again.success() && exact_existing.success();
    let environment_supported = environment.success()
        && environment
            .stdout
            .lines()
            .any(|line| line == "GHOSTHUB_PROBE=present");
    let exact = collision.success()
        && exact_existing.success()
        && !exact_prefix_miss.success()
        && exact_kill.success()
        && collision_survives.success()
        && !killed_absent.success();
    let stable_id = rename.success()
        && session_id.stdout.starts_with('$')
        && session_id.stdout == renamed_id.stdout;
    let server_identity = stop_server.success()
        && restart.success()
        && server_pid.stdout.parse::<u32>().is_ok()
        && restarted_pid.stdout.parse::<u32>().is_ok()
        && server_pid.stdout != restarted_pid.stdout;

    Ok(ProbeReport {
        version_output,
        observations: vec![
            proof("atomic-create-or-attach", atomic, &create, &create_again),
            proof(
                "new-session-environment",
                environment_supported,
                &environment,
                &environment,
            ),
            failed_proof(
                "attach-preserve-environment",
                "requires a genuine ConPTY attachment; redirected clients are invalid evidence",
            ),
            proof("exact-targets", exact, &exact_kill, &killed_absent),
            proof(
                "stable-session-identity",
                stable_id,
                &session_id,
                &renamed_id,
            ),
            proof(
                "server-instance-identity",
                server_identity,
                &server_pid,
                &restarted_pid,
            ),
            proof("isolated-namespace", create.success(), &create, &create),
        ],
    })
}

#[derive(Debug)]
struct CommandResult {
    exit_code: i32,
    stdout: String,
    stderr: String,
}

impl CommandResult {
    fn success(&self) -> bool {
        self.exit_code == 0
    }
}

fn run(
    executable: &str,
    namespace: &ProbeNamespace,
    command: &[&str],
) -> io::Result<CommandResult> {
    let output = Command::new(executable)
        .args(["-f", "NUL", "-L", namespace.as_str()])
        .args(command)
        .output()?;
    Ok(CommandResult {
        exit_code: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_owned(),
    })
}

fn proof(
    name: &str,
    supported: bool,
    primary: &CommandResult,
    secondary: &CommandResult,
) -> ProbeObservation {
    if supported {
        return ProbeObservation {
            name: name.to_owned(),
            exit_code: 0,
            stdout: "supported".to_owned(),
            stderr: String::new(),
        };
    }
    ProbeObservation {
        name: name.to_owned(),
        exit_code: primary.exit_code,
        stdout: primary.stdout.clone(),
        stderr: format!(
            "primary stderr: {}; secondary exit/stdout/stderr: {}/{}/{}",
            primary.stderr, secondary.exit_code, secondary.stdout, secondary.stderr
        ),
    }
}

fn failed_proof(name: &str, reason: &str) -> ProbeObservation {
    ProbeObservation {
        name: name.to_owned(),
        exit_code: -1,
        stdout: String::new(),
        stderr: reason.to_owned(),
    }
}

fn combined_output(stdout: &[u8], stderr: &[u8]) -> String {
    [
        String::from_utf8_lossy(stdout).trim(),
        String::from_utf8_lossy(stderr).trim(),
    ]
    .into_iter()
    .filter(|part| !part.is_empty())
    .collect::<Vec<_>>()
    .join("\n")
}

struct CleanupGuard<'a> {
    executable: &'a str,
    namespace: &'a ProbeNamespace,
}

impl Drop for CleanupGuard<'_> {
    fn drop(&mut self) {
        let _ = Command::new(self.executable)
            .args(["-f", "NUL", "-L", self.namespace.as_str(), "kill-server"])
            .output();
    }
}
