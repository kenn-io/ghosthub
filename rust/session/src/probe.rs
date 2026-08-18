//! Isolated psmux capability-probe command planning.

use std::{
    fmt,
    io::{self, Read},
    process::{Command, Stdio},
    sync::mpsc::{self, Receiver, RecvTimeoutError},
    thread,
    time::{Duration, Instant},
};

use crate::ProbeObservation;

const PREFIX: &str = "ghosthub-test-";
const COMMAND_TIMEOUT: Duration = Duration::from_secs(10);
const PIPE_TIMEOUT: Duration = Duration::from_secs(1);

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

    fn peer(&self) -> Self {
        Self(format!("{}-peer", self.0))
    }

    fn session(&self, role: &str) -> String {
        format!("{}-{role}", self.0)
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
#[allow(
    clippy::too_many_lines,
    reason = "the plan mirrors the ordered live transcript for safety auditing"
)]
pub fn psmux_probe_plan(namespace: &ProbeNamespace) -> Vec<ProbeCommand> {
    let peer = namespace.peer();
    let primary_sentinel = namespace.session("sentinel");
    let peer_sentinel = peer.session("sentinel");
    let primary_target = format!("={primary_sentinel}");
    let peer_target = format!("={peer_sentinel}");
    let main = namespace.session("main");
    let collision = namespace.session("main-old");
    let renamed = namespace.session("main-renamed");
    let restart = namespace.session("server-restart");
    let main_target = format!("={main}");
    let prefix_target = format!("={main}-o");
    let collision_target = format!("={collision}");
    let renamed_target = format!("={renamed}");
    let restart_target = format!("={restart}");

    vec![
        planned(
            namespace,
            "isolation-primary-create",
            &["new-session", "-d", "-s", &primary_sentinel],
        ),
        planned(
            &peer,
            "isolation-peer-create",
            &["new-session", "-d", "-s", &peer_sentinel],
        ),
        planned(
            namespace,
            "isolation-primary-present",
            &["has-session", "-t", &primary_target],
        ),
        planned(
            namespace,
            "isolation-peer-absent",
            &["has-session", "-t", &peer_target],
        ),
        planned(
            &peer,
            "isolation-peer-present",
            &["has-session", "-t", &peer_target],
        ),
        planned(
            &peer,
            "isolation-primary-absent",
            &["has-session", "-t", &primary_target],
        ),
        planned(
            namespace,
            "atomic-create-or-attach",
            &[
                "new-session",
                "-A",
                "-d",
                "-s",
                &main,
                "-e",
                "GHOSTHUB_PROBE=present",
            ],
        ),
        planned(
            namespace,
            "prefix-collision",
            &["new-session", "-d", "-s", &collision],
        ),
        planned(
            namespace,
            "exact-existing",
            &["has-session", "-t", &main_target],
        ),
        planned(
            namespace,
            "exact-prefix-miss",
            &["has-session", "-t", &prefix_target],
        ),
        planned(
            namespace,
            "new-session-environment",
            &["show-environment", "-t", &main_target, "GHOSTHUB_PROBE"],
        ),
        planned(
            namespace,
            "stable-session-identity",
            &["display-message", "-p", "-t", &main_target, "#{session_id}"],
        ),
        planned(
            namespace,
            "server-instance-identity",
            &["display-message", "-p", "-t", &main_target, "#{pid}"],
        ),
        planned(
            namespace,
            "attach-preserve-environment",
            &["attach-session", "-E", "-t", &main_target],
        ),
        planned(
            namespace,
            "rename",
            &["rename-session", "-t", &main_target, &renamed],
        ),
        planned(
            namespace,
            "exact-kill",
            &["kill-session", "-t", &renamed_target],
        ),
        planned(
            namespace,
            "collision-survives",
            &["has-session", "-t", &collision_target],
        ),
        planned(namespace, "stop-server", &["kill-server"]),
        planned(
            namespace,
            "restart-server",
            &["new-session", "-d", "-s", &restart],
        ),
        planned(
            namespace,
            "restarted-server-identity",
            &["display-message", "-p", "-t", &restart_target, "#{pid}"],
        ),
    ]
}

fn planned(namespace: &ProbeNamespace, name: &'static str, command: &[&str]) -> ProbeCommand {
    ProbeCommand {
        name,
        arguments: ["-f", "NUL", "-L", namespace.as_str()]
            .into_iter()
            .chain(command.iter().copied())
            .map(str::to_owned)
            .collect(),
    }
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
    let peer = namespace.peer();
    let primary_sentinel = namespace.session("sentinel");
    let peer_sentinel = peer.session("sentinel");
    let primary_sentinel_target = format!("={primary_sentinel}");
    let peer_sentinel_target = format!("={peer_sentinel}");
    let mut cleanup = CleanupGuard::unverified(
        executable,
        [
            (namespace.clone(), primary_sentinel.clone()),
            (peer.clone(), peer_sentinel.clone()),
        ],
    );
    let mut version_command = Command::new(executable);
    version_command.arg("-V");
    let version = run_process(&mut version_command, COMMAND_TIMEOUT)?;
    let version_output = combined_output(version.stdout.as_bytes(), version.stderr.as_bytes());

    let primary_create = run(
        executable,
        namespace,
        &["new-session", "-d", "-s", &primary_sentinel],
    )?;
    let peer_create = run(
        executable,
        &peer,
        &["new-session", "-d", "-s", &peer_sentinel],
    )?;
    let primary_present = run(
        executable,
        namespace,
        &["has-session", "-t", &primary_sentinel_target],
    )?;
    let peer_absent_from_primary = run(
        executable,
        namespace,
        &["has-session", "-t", &peer_sentinel_target],
    )?;
    let peer_present = run(
        executable,
        &peer,
        &["has-session", "-t", &peer_sentinel_target],
    )?;
    let primary_absent_from_peer = run(
        executable,
        &peer,
        &["has-session", "-t", &primary_sentinel_target],
    )?;
    let isolated = primary_create.success()
        && peer_create.success()
        && primary_present.success()
        && !peer_absent_from_primary.success()
        && peer_present.success()
        && !primary_absent_from_peer.success();
    if !isolated {
        return Ok(isolation_failure_report(
            version_output,
            &peer_absent_from_primary,
            &primary_absent_from_peer,
        ));
    }
    cleanup.mark_isolated(peer.clone());

    let main = namespace.session("main");
    let collision_name = namespace.session("main-old");
    let renamed = namespace.session("main-renamed");
    let restart_name = namespace.session("server-restart");
    let main_target = format!("={main}");
    let prefix_target = format!("={main}-o");
    let collision_target = format!("={collision_name}");
    let renamed_target = format!("={renamed}");
    let restart_target = format!("={restart_name}");

    let create = run(
        executable,
        namespace,
        &[
            "new-session",
            "-A",
            "-d",
            "-s",
            &main,
            "-e",
            "GHOSTHUB_PROBE=present",
        ],
    )?;
    let create_again = run(
        executable,
        namespace,
        &["new-session", "-A", "-d", "-s", &main],
    )?;
    let collision = run(
        executable,
        namespace,
        &["new-session", "-d", "-s", &collision_name],
    )?;
    let exact_existing = run(executable, namespace, &["has-session", "-t", &main_target])?;
    let exact_prefix_miss = run(
        executable,
        namespace,
        &["has-session", "-t", &prefix_target],
    )?;
    let environment = run(
        executable,
        namespace,
        &["show-environment", "-t", &main_target, "GHOSTHUB_PROBE"],
    )?;
    let session_id = run(
        executable,
        namespace,
        &["display-message", "-p", "-t", &main_target, "#{session_id}"],
    )?;
    let server_pid = run(
        executable,
        namespace,
        &["display-message", "-p", "-t", &main_target, "#{pid}"],
    )?;
    let rename = run(
        executable,
        namespace,
        &["rename-session", "-t", &main_target, &renamed],
    )?;
    let renamed_id = run(
        executable,
        namespace,
        &[
            "display-message",
            "-p",
            "-t",
            &renamed_target,
            "#{session_id}",
        ],
    )?;
    let exact_kill = run(
        executable,
        namespace,
        &["kill-session", "-t", &renamed_target],
    )?;
    let collision_survives = run(
        executable,
        namespace,
        &["has-session", "-t", &collision_target],
    )?;
    let killed_absent = run(
        executable,
        namespace,
        &["has-session", "-t", &renamed_target],
    )?;

    let stop_server = run(executable, namespace, &["kill-server"])?;
    let restart = run(
        executable,
        namespace,
        &["new-session", "-d", "-s", &restart_name],
    )?;
    let restarted_pid = run(
        executable,
        namespace,
        &["display-message", "-p", "-t", &restart_target, "#{pid}"],
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
            proof(
                "isolated-namespace",
                isolated,
                &peer_absent_from_primary,
                &primary_absent_from_peer,
            ),
        ],
    })
}

fn isolation_failure_report(
    version_output: String,
    primary_peer_check: &CommandResult,
    peer_primary_check: &CommandResult,
) -> ProbeReport {
    let reason = "namespace separation is a prerequisite for destructive capability probes";
    ProbeReport {
        version_output,
        observations: vec![
            failed_proof("atomic-create-or-attach", reason),
            failed_proof("new-session-environment", reason),
            failed_proof("attach-preserve-environment", reason),
            failed_proof("exact-targets", reason),
            failed_proof("stable-session-identity", reason),
            failed_proof("server-instance-identity", reason),
            proof(
                "isolated-namespace",
                false,
                primary_peer_check,
                peer_primary_check,
            ),
        ],
    }
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
    let mut process = Command::new(executable);
    process
        .args(["-f", "NUL", "-L", namespace.as_str()])
        .args(command);
    run_process(&mut process, COMMAND_TIMEOUT)
}

fn run_process(command: &mut Command, timeout: Duration) -> io::Result<CommandResult> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdout = drain_pipe(child.stdout.take().expect("piped stdout"));
    let stderr = drain_pipe(child.stderr.take().expect("piped stderr"));
    let started = Instant::now();
    let (status, timed_out) = loop {
        if let Some(status) = child.try_wait()? {
            break (status, false);
        }
        if started.elapsed() >= timeout {
            match child.kill() {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::InvalidInput => {}
                Err(error) => return Err(error),
            }
            break (child.wait()?, true);
        }
        thread::sleep(Duration::from_millis(10));
    };
    let (stdout, stdout_incomplete) = collect_pipe(&stdout)?;
    let (stderr, stderr_incomplete) = collect_pipe(&stderr)?;
    let mut stderr = String::from_utf8_lossy(&stderr).trim().to_owned();
    if timed_out {
        append_diagnostic(
            &mut stderr,
            &format!("timed out after {} ms", timeout.as_millis()),
        );
    }
    if stdout_incomplete || stderr_incomplete {
        append_diagnostic(&mut stderr, "output pipe remained open after process exit");
    }
    Ok(CommandResult {
        exit_code: if timed_out || stdout_incomplete || stderr_incomplete {
            -1
        } else {
            status.code().unwrap_or(-1)
        },
        stdout: String::from_utf8_lossy(&stdout).trim().to_owned(),
        stderr,
    })
}

fn drain_pipe(reader: impl Read + Send + 'static) -> Receiver<io::Result<Vec<u8>>> {
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let mut reader = reader;
        let mut bytes = Vec::new();
        let result = reader.read_to_end(&mut bytes).map(|_| bytes);
        let _ = sender.send(result);
    });
    receiver
}

fn collect_pipe(receiver: &Receiver<io::Result<Vec<u8>>>) -> io::Result<(Vec<u8>, bool)> {
    match receiver.recv_timeout(PIPE_TIMEOUT) {
        Ok(result) => result.map(|bytes| (bytes, false)),
        Err(RecvTimeoutError::Timeout) => Ok((Vec::new(), true)),
        Err(RecvTimeoutError::Disconnected) => Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            "output reader disconnected",
        )),
    }
}

fn append_diagnostic(output: &mut String, diagnostic: &str) {
    if !output.is_empty() {
        output.push_str("; ");
    }
    output.push_str(diagnostic);
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
    exact_sessions: Vec<(ProbeNamespace, String)>,
    isolated_namespaces: Option<[ProbeNamespace; 2]>,
}

impl<'a> CleanupGuard<'a> {
    fn unverified(
        executable: &'a str,
        exact_sessions: impl IntoIterator<Item = (ProbeNamespace, String)>,
    ) -> Self {
        Self {
            executable,
            exact_sessions: exact_sessions.into_iter().collect(),
            isolated_namespaces: None,
        }
    }

    fn mark_isolated(&mut self, peer: ProbeNamespace) {
        let primary = self.exact_sessions[0].0.clone();
        self.isolated_namespaces = Some([primary, peer]);
    }
}

impl Drop for CleanupGuard<'_> {
    fn drop(&mut self) {
        if let Some(namespaces) = &self.isolated_namespaces {
            for namespace in namespaces {
                let _ = run(self.executable, namespace, &["kill-server"]);
            }
            return;
        }
        for (namespace, session) in &self.exact_sessions {
            let target = format!("={session}");
            let _ = run(self.executable, namespace, &["kill-session", "-t", &target]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timed_out_child_is_killed_and_reported() {
        #[cfg(windows)]
        let mut command = {
            let mut command = Command::new("powershell.exe");
            command.args(["-NoProfile", "-Command", "Start-Sleep -Seconds 30"]);
            command
        };
        #[cfg(unix)]
        let mut command = {
            let mut command = Command::new("sleep");
            command.arg("30");
            command
        };
        let started = Instant::now();
        let result = run_process(&mut command, Duration::from_millis(100)).expect("run child");

        assert_eq!(result.exit_code, -1);
        assert!(result.stderr.contains("timed out after 100 ms"));
        assert!(started.elapsed() < Duration::from_secs(3));
    }
}
