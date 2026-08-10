use std::collections::{HashSet, VecDeque};
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use contracts::{Manifest, PlatformTag};
use host::{
    AdmissionAttacher, AttachTerm, CancellationToken, CommandOutput, CommandRunner, HerdrInventory,
    HostErrorKind, WslConfig, WslExecutable, WslHost,
};
use serde::Deserialize;
use session::ExecutablePlatform;
use session::{AdmissionPlan, HerdrSessionState, SessionName};

#[derive(Clone, Copy, Debug)]
struct AdmissionStatusFailure {
    command: &'static str,
    status: i32,
    stderr: &'static str,
}

#[derive(Debug)]
struct RecordingRunner {
    outputs: Mutex<VecDeque<io::Result<CommandOutput>>>,
    calls: Mutex<Vec<(OsString, Vec<OsString>)>>,
    timeouts: Mutex<Vec<std::time::Duration>>,
    admission_identity_count: Mutex<u32>,
    admission_environment: Mutex<String>,
    admission_attached: Arc<AtomicBool>,
    attachment_plans: Mutex<Vec<(OsString, Vec<OsString>)>>,
    removed_sessions: Mutex<HashSet<String>>,
    admission_sessions: Mutex<HashSet<(String, String)>>,
    admission_failure: Option<&'static str>,
    late_creation: Mutex<LateCreationState>,
    admission_status_failure: Mutex<Option<AdmissionStatusFailure>>,
    namespaces_are_isolated: bool,
    exact_targets_are_strict: bool,
    admission_directory: Mutex<AdmissionDirectoryState>,
    herdr_outputs: Mutex<VecDeque<CommandOutput>>,
}

#[derive(Debug, Default)]
struct AdmissionDirectoryState {
    exists: bool,
    create_after_next_remove: bool,
}

#[derive(Debug, Default)]
struct LateCreationState {
    enabled: bool,
    session: Option<String>,
    present: bool,
    cleanup_attempts: usize,
    cleanup_failures_remaining: usize,
    cleanup_verification_failures_remaining: usize,
}

impl RecordingRunner {
    fn new(outputs: Vec<CommandOutput>) -> Self {
        Self {
            outputs: Mutex::new(outputs.into_iter().map(Ok).collect()),
            calls: Mutex::new(Vec::new()),
            timeouts: Mutex::new(Vec::new()),
            admission_identity_count: Mutex::new(0),
            admission_environment: Mutex::new("present".to_owned()),
            admission_attached: Arc::new(AtomicBool::new(false)),
            attachment_plans: Mutex::new(Vec::new()),
            removed_sessions: Mutex::new(HashSet::new()),
            admission_sessions: Mutex::new(HashSet::new()),
            admission_failure: None,
            late_creation: Mutex::new(LateCreationState::default()),
            admission_status_failure: Mutex::new(None),
            namespaces_are_isolated: true,
            exact_targets_are_strict: true,
            admission_directory: Mutex::new(AdmissionDirectoryState::default()),
            herdr_outputs: Mutex::new(VecDeque::new()),
        }
    }

    fn failing_admission(command: &'static str) -> Self {
        Self {
            outputs: Mutex::new(VecDeque::from([Ok(instance_output())])),
            calls: Mutex::new(Vec::new()),
            timeouts: Mutex::new(Vec::new()),
            admission_identity_count: Mutex::new(0),
            admission_environment: Mutex::new("present".to_owned()),
            admission_attached: Arc::new(AtomicBool::new(false)),
            attachment_plans: Mutex::new(Vec::new()),
            removed_sessions: Mutex::new(HashSet::new()),
            admission_sessions: Mutex::new(HashSet::new()),
            admission_failure: Some(command),
            late_creation: Mutex::new(LateCreationState::default()),
            admission_status_failure: Mutex::new(None),
            namespaces_are_isolated: true,
            exact_targets_are_strict: true,
            admission_directory: Mutex::new(AdmissionDirectoryState::default()),
            herdr_outputs: Mutex::new(VecDeque::new()),
        }
    }

    fn rejecting_admission(command: &'static str) -> Self {
        Self {
            outputs: Mutex::new(VecDeque::from([Ok(instance_output())])),
            calls: Mutex::new(Vec::new()),
            timeouts: Mutex::new(Vec::new()),
            admission_identity_count: Mutex::new(0),
            admission_environment: Mutex::new("present".to_owned()),
            admission_attached: Arc::new(AtomicBool::new(false)),
            attachment_plans: Mutex::new(Vec::new()),
            removed_sessions: Mutex::new(HashSet::new()),
            admission_sessions: Mutex::new(HashSet::new()),
            admission_failure: None,
            late_creation: Mutex::new(LateCreationState::default()),
            admission_status_failure: Mutex::new(Some(AdmissionStatusFailure {
                command,
                status: 1,
                stderr: "scripted admission rejection",
            })),
            namespaces_are_isolated: true,
            exact_targets_are_strict: true,
            admission_directory: Mutex::new(AdmissionDirectoryState::default()),
            herdr_outputs: Mutex::new(VecDeque::new()),
        }
    }

    fn missing_admission_executable(command: &'static str) -> Self {
        Self::admission_status_failure(command, 127, "/usr/bin/env: '/missing/tmux': No such file")
    }

    fn admission_status_failure(command: &'static str, status: i32, stderr: &'static str) -> Self {
        Self {
            outputs: Mutex::new(VecDeque::from([Ok(instance_output())])),
            calls: Mutex::new(Vec::new()),
            timeouts: Mutex::new(Vec::new()),
            admission_identity_count: Mutex::new(0),
            admission_environment: Mutex::new("present".to_owned()),
            admission_attached: Arc::new(AtomicBool::new(false)),
            attachment_plans: Mutex::new(Vec::new()),
            removed_sessions: Mutex::new(HashSet::new()),
            admission_sessions: Mutex::new(HashSet::new()),
            admission_failure: None,
            late_creation: Mutex::new(LateCreationState::default()),
            admission_status_failure: Mutex::new(Some(AdmissionStatusFailure {
                command,
                status,
                stderr,
            })),
            namespaces_are_isolated: true,
            exact_targets_are_strict: true,
            admission_directory: Mutex::new(AdmissionDirectoryState::default()),
            herdr_outputs: Mutex::new(VecDeque::new()),
        }
    }

    fn ignoring_namespaces() -> Self {
        Self {
            outputs: Mutex::new(VecDeque::from([Ok(instance_output())])),
            calls: Mutex::new(Vec::new()),
            timeouts: Mutex::new(Vec::new()),
            admission_identity_count: Mutex::new(0),
            admission_environment: Mutex::new("present".to_owned()),
            admission_attached: Arc::new(AtomicBool::new(false)),
            attachment_plans: Mutex::new(Vec::new()),
            removed_sessions: Mutex::new(HashSet::new()),
            admission_sessions: Mutex::new(HashSet::new()),
            admission_failure: None,
            late_creation: Mutex::new(LateCreationState::default()),
            admission_status_failure: Mutex::new(None),
            namespaces_are_isolated: false,
            exact_targets_are_strict: true,
            admission_directory: Mutex::new(AdmissionDirectoryState::default()),
            herdr_outputs: Mutex::new(VecDeque::new()),
        }
    }

    fn ignoring_exact_targets() -> Self {
        let mut runner = Self::new(vec![instance_output()]);
        runner.exact_targets_are_strict = false;
        runner
    }

    fn timing_out_after_creation(command: &'static str) -> Self {
        let runner = Self::failing_admission(command);
        runner
            .late_creation
            .lock()
            .expect("late creation lock")
            .enabled = true;
        runner
    }

    fn with_cleanup_failures(kill_failures: usize, verification_failures: usize) -> Self {
        let runner = Self::new(vec![
            instance_output(),
            output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
            instance_output(),
        ]);
        {
            let mut cleanup = runner.late_creation.lock().expect("cleanup state lock");
            cleanup.cleanup_failures_remaining = kill_failures;
            cleanup.cleanup_verification_failures_remaining = verification_failures;
        }
        runner
    }

    fn late_creation_state(&self) -> (bool, usize) {
        let state = self.late_creation.lock().expect("late creation lock");
        (state.present, state.cleanup_attempts)
    }

    fn calls(&self) -> Vec<(OsString, Vec<OsString>)> {
        self.calls
            .lock()
            .expect("calls lock")
            .iter()
            .filter(|(_, args)| !is_admission_call(args) && !is_herdr_call(args))
            .cloned()
            .collect()
    }

    fn all_calls(&self) -> Vec<(OsString, Vec<OsString>)> {
        self.calls.lock().expect("calls lock").clone()
    }

    fn set_herdr_outputs(&self, outputs: Vec<CommandOutput>) {
        *self.herdr_outputs.lock().expect("Herdr outputs lock") = outputs.into();
    }

    fn all_timeouts(&self) -> Vec<std::time::Duration> {
        self.timeouts.lock().expect("timeouts lock").clone()
    }

    fn attachment_plans(&self) -> Vec<(OsString, Vec<OsString>)> {
        self.attachment_plans
            .lock()
            .expect("attachment plans lock")
            .clone()
    }

    fn admission_directory_exists(&self) -> bool {
        self.admission_directory
            .lock()
            .expect("admission directory lock")
            .exists
    }
}

struct RecordingClient {
    attached: Arc<AtomicBool>,
}

struct FailingAttacher;

struct BaselineTermAttacher<'a> {
    runner: &'a RecordingRunner,
}

impl AdmissionAttacher for FailingAttacher {
    type Client = ();

    fn attach(&self, _plan: &AdmissionPlan) -> Result<Self::Client, String> {
        Err("scripted ConPTY failure".to_owned())
    }
}

impl AdmissionAttacher for BaselineTermAttacher<'_> {
    type Client = RecordingClient;

    fn attach(&self, plan: &AdmissionPlan) -> Result<Self::Client, String> {
        if plan
            .args()
            .iter()
            .any(|argument| argument == "TERM=xterm-256color")
        {
            return Err("xterm-256color terminfo is unavailable".to_owned());
        }
        self.runner.attach(plan)
    }
}

impl Drop for RecordingClient {
    fn drop(&mut self) {
        self.attached.store(false, Ordering::Release);
    }
}

impl AdmissionAttacher for RecordingRunner {
    type Client = RecordingClient;

    fn attach(&self, plan: &AdmissionPlan) -> Result<Self::Client, String> {
        self.attachment_plans
            .lock()
            .expect("attachment plans lock")
            .push((plan.program().to_owned(), plan.args().to_vec()));
        if !plan.args().iter().any(|argument| argument == "-E")
            && let Some(value) = plan.args().iter().find_map(|argument| {
                argument
                    .to_str()
                    .and_then(|argument| argument.strip_prefix("GHOSTHUB_PROBE="))
            })
        {
            value.clone_into(&mut self.admission_environment.lock().expect("environment lock"));
        }
        self.admission_attached.store(true, Ordering::Release);
        Ok(RecordingClient {
            attached: Arc::clone(&self.admission_attached),
        })
    }
}

impl CommandRunner for RecordingRunner {
    #[allow(
        clippy::too_many_lines,
        reason = "the scripted runner records one subprocess boundary"
    )]
    fn run(
        &self,
        program: &OsStr,
        args: &[OsString],
        _cancellation: &CancellationToken,
        timeout: std::time::Duration,
    ) -> io::Result<CommandOutput> {
        self.calls
            .lock()
            .expect("calls lock")
            .push((program.to_owned(), args.to_vec()));
        self.timeouts.lock().expect("timeouts lock").push(timeout);
        if is_herdr_call(args) {
            return Ok(self
                .herdr_outputs
                .lock()
                .expect("Herdr outputs lock")
                .pop_front()
                .unwrap_or_else(|| output(127, "", "herdr: not found")));
        }
        if self
            .admission_failure
            .is_some_and(|failed| admission_command(args).is_some_and(|command| command == failed))
        {
            let mut late_creation = self.late_creation.lock().expect("late creation lock");
            if late_creation.enabled {
                late_creation.session = argument_after(args, "-s").map(str::to_owned);
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "scripted command completed after its caller timed out",
                ));
            }
            return Err(if admission_command(args) == Some("mkdir") {
                self.admission_directory
                    .lock()
                    .expect("admission directory lock")
                    .create_after_next_remove = true;
                io::Error::new(io::ErrorKind::TimedOut, "scripted admission timeout")
            } else {
                io::Error::other("scripted admission failure")
            });
        }
        if args.iter().any(|argument| argument == "/usr/bin/mkdir") {
            self.admission_directory
                .lock()
                .expect("admission directory lock")
                .exists = true;
            return Ok(output(0, "", ""));
        }
        if args.iter().any(|argument| argument == "/usr/bin/rm") {
            let mut directory = self
                .admission_directory
                .lock()
                .expect("admission directory lock");
            directory.exists = false;
            if directory.create_after_next_remove {
                directory.exists = true;
                directory.create_after_next_remove = false;
            }
            return Ok(output(0, "", ""));
        }
        if args.iter().any(|argument| argument == "/usr/bin/test") {
            let exists = self
                .admission_directory
                .lock()
                .expect("admission directory lock")
                .exists;
            return Ok(output(i32::from(exists), "", ""));
        }
        let admission_command = admission_command(args);
        if timeout <= std::time::Duration::from_millis(500) {
            let mut cleanup = self.late_creation.lock().expect("cleanup state lock");
            if matches!(admission_command, Some("kill-session" | "kill-server"))
                && cleanup.cleanup_failures_remaining > 0
            {
                cleanup.cleanup_failures_remaining -= 1;
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "scripted cleanup termination timeout",
                ));
            }
            if admission_command == Some("list-sessions")
                && cleanup.cleanup_verification_failures_remaining > 0
            {
                cleanup.cleanup_verification_failures_remaining -= 1;
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "scripted cleanup verification timeout",
                ));
            }
        }
        if matches!(admission_command, Some("kill-session" | "kill-server")) {
            let mut late_creation = self.late_creation.lock().expect("late creation lock");
            let targets_late_session = admission_command == Some("kill-server")
                || argument_after(args, "-t").is_some_and(|target| {
                    late_creation
                        .session
                        .as_deref()
                        .is_some_and(|session| target.trim_start_matches('=') == session)
                });
            if late_creation.enabled && targets_late_session {
                late_creation.cleanup_attempts += 1;
                if late_creation.present {
                    late_creation.present = false;
                } else if late_creation.cleanup_attempts == 1 {
                    late_creation.present = true;
                }
            }
        }
        let mut status_failure = self
            .admission_status_failure
            .lock()
            .expect("status failure lock");
        if status_failure
            .as_ref()
            .is_some_and(|failed| admission_command == Some(failed.command))
        {
            let failure = status_failure.take().expect("status failure");
            return Ok(output(failure.status, "", failure.stderr));
        }
        if let Some(output) = admission_output(
            args,
            &self.admission_identity_count,
            &self.admission_environment,
            &self.admission_attached,
            &self.removed_sessions,
            &self.admission_sessions,
            self.namespaces_are_isolated,
            self.exact_targets_are_strict,
        ) {
            return Ok(output);
        }
        self.outputs
            .lock()
            .expect("outputs lock")
            .pop_front()
            .expect("scripted command output")
    }
}

fn is_admission_call(args: &[OsString]) -> bool {
    args.iter().any(|argument| {
        argument.to_str().is_some_and(|argument| {
            argument.starts_with("ghv-") || argument.starts_with("/tmp/ghosthub-tmux-probe.")
        })
    }) || args.last().is_some_and(|argument| argument == "-V")
}

fn is_herdr_call(args: &[OsString]) -> bool {
    args.iter().any(|argument| {
        argument
            .to_str()
            .is_some_and(|argument| argument.contains("GHOSTHUB_HERDR_PATH"))
    }) || args
        .windows(3)
        .any(|arguments| arguments == ["session", "list", "--json"])
}

#[allow(
    clippy::too_many_arguments,
    clippy::too_many_lines,
    reason = "the admission simulator keeps each tmux command's state transition visible"
)]
fn admission_output(
    args: &[OsString],
    identity_count: &Mutex<u32>,
    environment: &Mutex<String>,
    attached: &AtomicBool,
    removed_sessions: &Mutex<HashSet<String>>,
    sessions: &Mutex<HashSet<(String, String)>>,
    namespaces_are_isolated: bool,
    exact_targets_are_strict: bool,
) -> Option<CommandOutput> {
    if args.last().is_some_and(|argument| argument == "-V") {
        return Some(output(0, "tmux 3.4\n", ""));
    }
    if !is_admission_call(args) {
        return None;
    }
    let command = admission_command(args)?;
    Some(match command {
        "new-session" => {
            let namespace = argument_after(args, "-L").unwrap_or_default().to_owned();
            let session = argument_after(args, "-s").unwrap_or_default().to_owned();
            sessions
                .lock()
                .expect("admission sessions lock")
                .insert((namespace, session));
            if let Some(value) = argument_after(args, "-e")
                .and_then(|argument| argument.strip_prefix("GHOSTHUB_PROBE="))
            {
                value.clone_into(&mut environment.lock().expect("environment lock"));
            }
            output(0, "", "")
        }
        "set-option" => output(0, "", ""),
        "rename-session" => {
            let namespace = argument_after(args, "-L").unwrap_or_default().to_owned();
            let old = argument_after(args, "-t")
                .unwrap_or_default()
                .trim_start_matches('=')
                .to_owned();
            let new = args
                .last()
                .expect("new session name")
                .to_string_lossy()
                .into_owned();
            let mut sessions = sessions.lock().expect("admission sessions lock");
            sessions.remove(&(namespace.clone(), old));
            sessions.insert((namespace, new));
            output(0, "", "")
        }
        "kill-session" => {
            if let Some(target) = argument_after(args, "-t") {
                sessions.lock().expect("admission sessions lock").remove(&(
                    argument_after(args, "-L").unwrap_or_default().to_owned(),
                    target.trim_start_matches('=').to_owned(),
                ));
                removed_sessions
                    .lock()
                    .expect("removed sessions lock")
                    .insert(target.trim_start_matches('=').to_owned());
            }
            output(0, "", "")
        }
        "kill-server" => {
            let namespace = argument_after(args, "-L").unwrap_or_default();
            sessions
                .lock()
                .expect("admission sessions lock")
                .retain(|(candidate, _)| candidate != namespace);
            *identity_count.lock().expect("identity count lock") += 1;
            output(0, "", "")
        }
        "set-environment" => {
            *environment.lock().expect("environment lock") = args
                .last()
                .expect("environment value")
                .to_string_lossy()
                .into_owned();
            output(0, "", "")
        }
        "show-environment" => output(
            0,
            &format!(
                "GHOSTHUB_PROBE={}\n",
                environment.lock().expect("environment lock")
            ),
            "",
        ),
        "list-sessions" => {
            let count = *identity_count.lock().expect("identity count lock");
            let namespace = argument_after(args, "-L").expect("isolated namespace");
            if !sessions
                .lock()
                .expect("admission sessions lock")
                .iter()
                .any(|(candidate, _)| candidate == namespace)
            {
                return Some(output(1, "", "no server running on private socket"));
            }
            let suffix = namespace
                .strip_prefix("ghv-")
                .expect("primary admission namespace");
            let session = format!("ghc-{suffix}");
            output(
                0,
                &format!(
                    "{}\t$1\t{}\t{session}\n{}\t$1\t{}\t{session}-renamed\n",
                    4242 + count,
                    session.len(),
                    4242 + count,
                    session.len() + "-renamed".len(),
                ),
                "",
            )
        }
        "list-clients" => output(
            0,
            if attached.load(Ordering::Acquire) {
                "$1\n"
            } else {
                ""
            },
            "",
        ),
        "has-session" => {
            let namespace = argument_after(args, "-L").unwrap_or_default();
            let target = argument_after(args, "-t").unwrap_or_default();
            let missing = (exact_targets_are_strict && target.ends_with("-o"))
                || removed_sessions
                    .lock()
                    .expect("removed sessions lock")
                    .contains(target.trim_start_matches('='));
            let name = target.trim_start_matches('=');
            let present = sessions
                .lock()
                .expect("admission sessions lock")
                .iter()
                .any(|(candidate_namespace, candidate_name)| {
                    (!namespaces_are_isolated || candidate_namespace == namespace)
                        && if exact_targets_are_strict || !target.starts_with('=') {
                            candidate_name == name
                        } else {
                            candidate_name.starts_with(name)
                        }
                });
            if !missing && present {
                output(0, "", "")
            } else {
                output(1, "", "can't find session")
            }
        }
        other => panic!("unexpected admission command: {other}"),
    })
}

fn admission_command(args: &[OsString]) -> Option<&str> {
    if args.last().is_some_and(|argument| argument == "-V") {
        return Some("-V");
    }
    args.iter().find_map(|argument| {
        let argument = argument.to_str()?;
        if argument == "/usr/bin/mkdir" {
            return Some("mkdir");
        }
        matches!(
            argument,
            "new-session"
                | "kill-session"
                | "kill-server"
                | "show-environment"
                | "set-environment"
                | "set-option"
                | "list-sessions"
                | "list-clients"
                | "has-session"
                | "rename-session"
        )
        .then_some(argument)
    })
}

fn argument_after<'a>(args: &'a [OsString], flag: &str) -> Option<&'a str> {
    args.windows(2)
        .find_map(|pair| (pair[0] == flag).then(|| pair[1].to_str()).flatten())
}

fn has_tmux_environment_scrub(args: &[OsString]) -> bool {
    args.windows(7).any(|window| {
        window
            == [
                "/usr/bin/env",
                "-u",
                "TMUX",
                "-u",
                "TMUX_PANE",
                "-u",
                "TMUX_TMPDIR",
            ]
    })
}

fn assert_private_admission_isolation(
    admission_calls: &[&(OsString, Vec<OsString>)],
    attachment_plans: &[(OsString, Vec<OsString>)],
) {
    let private_path = admission_calls
        .iter()
        .find(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/mkdir"))
        .and_then(|(_, args)| args.last())
        .expect("private directory path")
        .to_string_lossy();
    let private_tmpdir = format!("TMUX_TMPDIR={private_path}");
    let nonce = private_path
        .rsplit('-')
        .next()
        .expect("private directory nonce");
    assert_eq!(nonce.len(), 32);
    let name_nonce = &nonce[..16];
    assert!(
        admission_calls
            .iter()
            .filter(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/tmux"))
            .all(|(_, args)| {
                args.iter()
                    .any(|argument| argument == OsStr::new(&private_tmpdir))
            }),
        "every admission tmux command must use the private socket root"
    );
    assert!(attachment_plans.iter().all(|(_, args)| {
        args.iter()
            .any(|argument| argument == OsStr::new(&private_tmpdir))
            && has_tmux_environment_scrub(args)
    }));
    assert!(admission_calls.iter().all(|(_, args)| {
        args.iter()
            .filter_map(|argument| argument.to_str())
            .all(|argument| {
                !argument.starts_with("ghv-")
                    && !argument.starts_with("ghc-")
                    && !argument.starts_with("ghp-")
                    || argument.contains(name_nonce)
            })
    }));
    let mktemp_index = admission_calls
        .iter()
        .position(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/mkdir"))
        .expect("private directory creation");
    let first_create_index = admission_calls
        .iter()
        .position(|(_, args)| args.iter().any(|argument| argument == "new-session"))
        .expect("first admission session creation");
    let remove_index = admission_calls
        .iter()
        .rposition(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/rm"))
        .expect("private directory cleanup");
    assert!(mktemp_index < first_create_index);
    assert!(remove_index > first_create_index);
}

fn assert_cleanup_verification_count(
    admission_calls: &[&(OsString, Vec<OsString>)],
    expected: usize,
) {
    assert_eq!(
        admission_calls
            .iter()
            .filter(|(_, args)| {
                args.iter().any(|argument| argument == "list-sessions")
                    && !args.iter().any(|argument| argument == "-F")
            })
            .count(),
        expected,
        "cleanup verifies each private server is absent"
    );
}

fn output(status: i32, stdout: &str, stderr: &str) -> CommandOutput {
    CommandOutput {
        status,
        stdout: stdout.as_bytes().to_vec(),
        stderr: stderr.as_bytes().to_vec(),
    }
}

fn discover(host: &WslHost<RecordingRunner>) -> Result<host::HostSnapshot, host::HostError> {
    host.discover(host.runner())
}

fn test_host(config: WslConfig, runner: RecordingRunner) -> WslHost<RecordingRunner> {
    WslHost::new(
        config,
        runner,
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe")
            .expect("absolute system WSL path"),
    )
}

#[test]
fn rejects_a_bare_wsl_executable_name() {
    assert!(WslExecutable::from_absolute("wsl.exe").is_err());
}

fn instance_output() -> CommandOutput {
    instance_output_with("65c18272-9676-4d59-9f67-ff4556cd1601", 987_654)
}

fn instance_output_with(boot_id: &str, start_ticks: u64) -> CommandOutput {
    output(
        0,
        &format!(
            "Linux version 6.6.114.1-microsoft-standard-WSL2\n\
             {boot_id}\n\
             1 (systemd) S 0 1 1 0 -1 4194560 1 2 3 4 5 6 7 8 9 10 11 12 {start_ticks} 15\n"
        ),
        "",
    )
}

#[test]
fn retries_discovery_when_the_distro_restarts_between_crossings() {
    let old = instance_output_with("65c18272-9676-4d59-9f67-ff4556cd1601", 100);
    let new = instance_output_with("91d83b4d-2b1a-47b7-bd2d-5d5bb698bdf7", 200);
    let runner = RecordingRunner::new(vec![
        old,
        output(0, "4242\t$3\t1700000000\t0\t5\tstale\n", ""),
        new.clone(),
        output(0, "5252\t$4\t1700000001\t0\t5\tfresh\n", ""),
        new,
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let snapshot = discover(&host).expect("retry stable discovery");

    assert_eq!(snapshot.runtime().init_start_ticks(), 200);
    assert_eq!(snapshot.sessions()[0].name(), "fresh");
    assert_eq!(host.runner().calls().len(), 5);
    assert_eq!(
        host.runner().attachment_plans().len(),
        6,
        "the replacement runtime must receive its own ordinary-client admission proof"
    );
}

#[test]
fn rejects_malformed_runtime_and_session_identity() {
    for runtime in [
        instance_output_with("not-a-uuid", 100),
        output(
            0,
            "Linux version 6.6.114.1-microsoft-standard-WSL2\n\
             65c18272-9676-4d59-9f67-ff4556cd1601\n\
             2 (systemd) S 0 1 1 0 -1 4194560 1 2 3 4 5 6 7 8 9 10 11 12 100 15\n",
            "",
        ),
    ] {
        let host = test_host(
            WslConfig::with_distro("Ubuntu").expect("valid config"),
            RecordingRunner::new(vec![runtime, output(0, "", "")]),
        );
        assert_eq!(
            discover(&host)
                .expect_err("identity must be rejected")
                .kind(),
            HostErrorKind::MalformedOutput
        );
    }

    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::new(vec![
            instance_output(),
            output(0, "4242\tnot-an-id\t1700000000\t0\t4\twork\n", ""),
        ]),
    );
    assert_eq!(
        discover(&host)
            .expect_err("session ID must be rejected")
            .kind(),
        HostErrorKind::MalformedOutput
    );
}

#[test]
fn default_distro_with_no_tmux_server_is_empty_inventory() {
    let runner = RecordingRunner::new(vec![
        output(0, "PATH=/usr/bin\nWSL_DISTRO_NAME=Ubuntu\n", ""),
        instance_output(),
        output(
            1,
            "",
            "error connecting to /tmp/tmux-1000/default (No such file or directory)\n",
        ),
        instance_output(),
    ]);
    let host = test_host(WslConfig::default(), runner);

    let snapshot = discover(&host).expect("no server is not an error");

    assert_eq!(snapshot.endpoint().distro(), "Ubuntu");
    assert!(snapshot.sessions().is_empty());
    assert_eq!(snapshot.runtime().init_start_ticks(), 987_654);
    assert_eq!(host.runner().calls().len(), 4);
}

#[test]
fn discovers_identity_in_one_tmux_crossing() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t1\t9\twork name\n", ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let snapshot = discover(&host).expect("discover sessions");
    let session = snapshot.sessions().first().expect("one session");

    assert_eq!(session.name(), "work name");
    assert_eq!(session.identity().server_pid(), 4242);
    assert_eq!(session.identity().session_id(), "$3");
    assert_eq!(session.identity().created_at(), 1_700_000_000);
    assert_eq!(session.attached_clients(), 1);
    assert_eq!(host.runner().calls().len(), 3);
}

#[test]
fn herdr_inventory_is_additive_and_scrubs_control_environment() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t1\t4\twork\n", ""),
        instance_output(),
    ]);
    runner.set_herdr_outputs(vec![
        output(0, "GHOSTHUB_HERDR_PATH\n/opt/herdr/bin/herdr\n", ""),
        output(
            0,
            r#"{"sessions":[{"name":"default","default":true,"running":true,"session_dir":"/tmp/herdr/default","socket_path":"/tmp/herdr/default/herdr.sock"},{"name":"review","default":false,"running":false,"session_dir":"/tmp/herdr/review","socket_path":"/tmp/herdr/review/herdr.sock"}]}"#,
            "",
        ),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let snapshot = discover(&host).expect("tmux discovery remains authoritative");

    let HerdrInventory::Available {
        executable,
        sessions,
    } = snapshot.herdr()
    else {
        panic!("Herdr is available");
    };
    assert_eq!(executable, "/opt/herdr/bin/herdr");
    assert_eq!(sessions.len(), 2);
    assert_eq!(sessions[0].state(), HerdrSessionState::Running);
    assert_eq!(sessions[1].state(), HerdrSessionState::Stopped);
    let resolve_call = host
        .runner()
        .all_calls()
        .into_iter()
        .find(|(_, args)| {
            args.last()
                .is_some_and(|argument| argument.to_string_lossy().contains("command -v herdr"))
        })
        .expect("Herdr executable resolution call");
    assert!(
        resolve_call
            .1
            .windows(2)
            .any(|arguments| arguments == ["/bin/sh", "-lc"]),
        "WSL capability resolution must load the POSIX login profile"
    );
    let list_call = host
        .runner()
        .all_calls()
        .into_iter()
        .find(|(_, args)| {
            args.windows(3)
                .any(|arguments| arguments == ["session", "list", "--json"])
        })
        .expect("Herdr list call");
    assert!(
        list_call
            .1
            .iter()
            .any(|argument| argument == "/opt/herdr/bin/herdr")
    );
    for variable in [
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
    ] {
        assert!(list_call.1.windows(2).any(|pair| pair == ["-u", variable]));
    }
}

#[test]
fn malformed_herdr_inventory_does_not_hide_tmux_sessions() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t1\t4\twork\n", ""),
        instance_output(),
    ]);
    runner.set_herdr_outputs(vec![
        output(0, "GHOSTHUB_HERDR_PATH\n/opt/herdr/bin/herdr\n", ""),
        output(0, "not-json", ""),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let snapshot = discover(&host).expect("Herdr failure is host-capability scoped");

    assert_eq!(snapshot.sessions()[0].name(), "work");
    assert!(
        matches!(snapshot.herdr(), HerdrInventory::Failed(error) if error.kind() == HostErrorKind::MalformedOutput)
    );
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "the admission transcript assertions stay together for safety auditing"
)]
fn admission_uses_inert_sessions_and_always_cleans_its_namespaces() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    discover(&host).expect("admit tmux and discover sessions");

    let calls = host.runner().all_calls();
    let admission_calls = calls
        .iter()
        .filter(|(_, args)| is_admission_call(args))
        .collect::<Vec<_>>();
    let created = admission_calls
        .iter()
        .filter(|(_, args)| args.iter().any(|argument| argument == "new-session"))
        .collect::<Vec<_>>();
    assert_eq!(created.len(), 4);
    assert!(created.iter().all(|(_, args)| {
        args.iter()
            .any(|argument| argument == "exec /usr/bin/sleep 60")
    }));
    assert_eq!(
        created
            .iter()
            .filter(|(_, args)| args.iter().any(|argument| argument == "-A"))
            .count(),
        0
    );
    assert!(admission_calls.iter().any(|(_, args)| {
        args.iter().any(|argument| argument == "rename-session")
            && args
                .last()
                .is_some_and(|argument| argument.to_string_lossy().ends_with("-renamed"))
    }));
    assert_eq!(
        admission_calls
            .iter()
            .filter(|(_, args)| {
                args.iter().any(|argument| argument == "list-sessions")
                    && args.iter().any(|argument| argument == "-F")
            })
            .count(),
        3
    );
    assert!(admission_calls.iter().all(|(_, args)| {
        !args.iter().any(|argument| argument == "list-sessions")
            || !args.iter().any(|argument| argument == "-F")
            || argument_after(args, "-F")
                == Some("#{pid}\t#{session_id}\t#{n:session_name}\t#{session_name}")
    }));
    assert_cleanup_verification_count(&admission_calls, 2);
    assert!(admission_calls.iter().any(|(_, args)| {
        args.iter().any(|argument| argument == "has-session")
            && argument_after(args, "-t").is_some_and(|target| target.ends_with("-old"))
    }));
    let captured_attachments = admission_calls
        .iter()
        .filter(|(_, args)| args.iter().any(|argument| argument == "attach-session"))
        .collect::<Vec<_>>();
    assert_eq!(
        captured_attachments.len(),
        0,
        "captured control-mode processes are not valid attachment evidence"
    );
    let attachment_plans = host.runner().attachment_plans();
    assert_eq!(attachment_plans.len(), 3);
    assert_eq!(
        attachment_plans
            .iter()
            .filter(|(_, args)| {
                args.iter().any(|argument| argument == "new-session")
                    && args.iter().any(|argument| argument == "-A")
            })
            .count(),
        1
    );
    assert!(attachment_plans.iter().any(|(_, args)| {
        args.iter().any(|argument| argument == "new-session")
            && args.iter().any(|argument| argument == "-A")
            && args.iter().any(|argument| argument == "-E")
            && args
                .iter()
                .any(|argument| argument == "GHOSTHUB_PROBE=ignored")
    }));
    assert_eq!(
        attachment_plans
            .iter()
            .filter(|(_, args)| args.iter().any(|argument| argument == "-E"))
            .count(),
        2
    );
    assert!(
        admission_calls
            .iter()
            .filter(|(_, args)| args.iter().any(|argument| argument == "kill-server"))
            .count()
            >= 3
    );
    assert_private_admission_isolation(&admission_calls, &attachment_plans);
}

#[test]
fn admission_does_not_require_xterm_256color_terminfo() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );
    let attacher = BaselineTermAttacher {
        runner: host.runner(),
    };

    let snapshot = host
        .discover(&attacher)
        .expect("baseline xterm admission succeeds without xterm-256color");

    let plans = host.runner().attachment_plans();
    assert_eq!(plans.len(), 3);
    assert!(plans.iter().all(|(_, args)| {
        args.iter().any(|argument| argument == "TERM=xterm")
            && !args
                .iter()
                .any(|argument| argument == "TERM=xterm-256color")
    }));
    let (creation, term) = host
        .create_once(
            snapshot.endpoint(),
            snapshot.runtime(),
            SessionName::parse("baseline").expect("valid session name"),
        )
        .expect("baseline creation authority");
    let (_, args, _, _) = creation.into_parts();
    assert_eq!(term, AttachTerm::Xterm);
    assert!(args.iter().any(|argument| argument == "TERM=xterm"));
    assert!(
        !args
            .iter()
            .any(|argument| argument == "TERM=xterm-256color")
    );
}

#[test]
fn admission_uses_xterm_256color_for_creation_when_the_client_proves_it() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );
    let snapshot = discover(&host).expect("admit full-color tmux client");

    let (creation, term) = host
        .create_once(
            snapshot.endpoint(),
            snapshot.runtime(),
            SessionName::parse("full-color").expect("valid session name"),
        )
        .expect("full-color creation authority");
    let (_, args, _, _) = creation.into_parts();

    assert_eq!(term, AttachTerm::Xterm256Color);
    assert!(
        args.iter()
            .any(|argument| argument == "TERM=xterm-256color")
    );
}

#[test]
fn cleanup_retries_failed_termination_before_removing_the_socket_root() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::with_cleanup_failures(1, 0),
    );

    discover(&host).expect("admission succeeds after cleanup retry");

    let calls = host.runner().all_calls();
    assert!(
        calls
            .iter()
            .filter(|(_, args)| args.iter().any(|argument| argument == "kill-server"))
            .count()
            > 2,
        "a failed private-server termination is retried"
    );
    assert!(
        !host.runner().admission_directory_exists(),
        "the socket root is removed only after absence is confirmed"
    );
}

#[test]
fn cleanup_preserves_the_socket_root_when_absence_cannot_be_confirmed() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::with_cleanup_failures(0, usize::MAX),
    );

    discover(&host).expect("admission result is independent of best-effort cleanup reporting");

    assert!(
        host.runner().admission_directory_exists(),
        "an unverified server must remain reachable through its private socket root"
    );
    assert!(
        !host
            .runner()
            .all_calls()
            .iter()
            .any(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/rm")),
        "unconfirmed termination must not unlink the private socket path"
    );
}

#[test]
fn admission_failure_before_isolation_cleans_only_created_sessions() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::failing_admission("show-environment"),
    );

    discover(&host).expect_err("admission must fail");

    let calls = host.runner().all_calls();
    assert!(
        !calls
            .iter()
            .any(|(_, args)| { args.iter().any(|argument| argument == "kill-server") })
    );
    assert_eq!(
        calls
            .iter()
            .filter(|(_, args)| args.iter().any(|argument| argument == "kill-session"))
            .count(),
        1
    );
}

#[test]
fn timed_out_session_creation_is_prearmed_for_cleanup() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::timing_out_after_creation("new-session"),
    );

    let error = discover(&host).expect_err("late session creation must still time out");

    assert_eq!(error.kind(), HostErrorKind::Timeout);
    let calls = host.runner().all_calls();
    let created = calls
        .iter()
        .find(|(_, args)| args.iter().any(|argument| argument == "new-session"))
        .and_then(|(_, args)| argument_after(args, "-s"))
        .expect("attempted session name");
    let cleanup_target = format!("={created}");
    assert!(calls.iter().any(|(_, args)| {
        args.iter().any(|argument| argument == "kill-session")
            && argument_after(args, "-t") == Some(cleanup_target.as_str())
    }));
    let (late_session_present, cleanup_attempts) = host.runner().late_creation_state();
    assert!(
        cleanup_attempts > 1,
        "ambiguous creation must be terminated throughout the settle window"
    );
    assert!(
        !late_session_present,
        "cleanup after the simulated late completion must win"
    );
    for ((_, args), timeout) in calls.iter().zip(host.runner().all_timeouts()) {
        if args
            .iter()
            .any(|argument| matches!(argument.to_str(), Some("kill-session" | "kill-server")))
        {
            assert!(timeout <= std::time::Duration::from_millis(500));
        }
    }
}

#[test]
fn cancelled_admission_directory_creation_cleans_the_preselected_path() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::failing_admission("mkdir"),
    );

    let error = discover(&host).expect_err("directory creation must time out");

    assert_eq!(error.kind(), HostErrorKind::Timeout);
    let calls = host.runner().all_calls();
    let mkdir_path = calls
        .iter()
        .find(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/mkdir"))
        .and_then(|(_, args)| args.last())
        .expect("preselected mkdir path");
    let remove_path = calls
        .iter()
        .rfind(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/rm"))
        .and_then(|(_, args)| args.last())
        .expect("cleanup path");
    assert_eq!(mkdir_path, remove_path);
    assert!(
        calls
            .iter()
            .filter(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/rm"))
            .count()
            > 1,
        "uncertain creation must keep removing through the duration-based settle window"
    );
    assert!(calls.iter().any(|(_, args)| {
        args.iter().any(|argument| argument == "/usr/bin/test") && args.last() == Some(remove_path)
    }));
    assert!(
        !host.runner().admission_directory_exists(),
        "a removal after the near-deadline simulated mkdir must win"
    );
    assert!(
        !calls
            .iter()
            .any(|(_, args)| args.iter().any(|argument| argument == "/usr/bin/tmux"))
    );
}

#[test]
fn failed_real_client_probe_is_not_cached_as_verified() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let error = host
        .discover(&FailingAttacher)
        .expect_err("failed ConPTY proof must reject admission");
    assert_eq!(error.kind(), HostErrorKind::Transport);

    discover(&host).expect("a later real-client proof can retry admission");
    assert_eq!(
        host.runner()
            .all_calls()
            .iter()
            .filter(|(_, args)| args.last().is_some_and(|argument| argument == "-V"))
            .count(),
        2,
        "failed attachment evidence must never populate the verification cache"
    );
}

#[test]
fn ignored_namespaces_are_rejected_without_killing_any_server() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::ignoring_namespaces(),
    );

    assert_eq!(
        discover(&host)
            .expect_err("namespace isolation is required")
            .kind(),
        HostErrorKind::UnsupportedEnvironment
    );

    let calls = host.runner().all_calls();
    assert!(
        !calls
            .iter()
            .any(|(_, args)| { args.iter().any(|argument| argument == "kill-server") })
    );
    assert_eq!(
        calls
            .iter()
            .filter(|(_, args)| args.iter().any(|argument| argument == "kill-session"))
            .count(),
        3
    );
    assert!(
        !calls
            .iter()
            .any(|(_, args)| { args.iter().any(|argument| argument == "attach-session") })
    );
}

#[test]
fn prefix_matching_exact_targets_are_rejected() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::ignoring_exact_targets(),
    );

    assert_eq!(
        discover(&host)
            .expect_err("prefix-matching exact targets must fail admission")
            .kind(),
        HostErrorKind::UnsupportedEnvironment
    );
    assert!(host.runner().all_calls().iter().any(|(_, args)| {
        args.iter().any(|argument| argument == "has-session")
            && argument_after(args, "-t").is_some_and(|target| target.ends_with("-o"))
    }));
}

#[test]
fn failed_primary_creation_never_reaches_server_wide_commands() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::rejecting_admission("new-session"),
    );

    assert_eq!(
        discover(&host)
            .expect_err("both namespace sessions must exist")
            .kind(),
        HostErrorKind::UnsupportedEnvironment
    );

    let calls = host.runner().all_calls();
    assert!(!calls.iter().any(|(_, args)| {
        args.iter()
            .any(|argument| matches!(argument.to_str(), Some("kill-server" | "set-option")))
    }));
}

#[test]
fn preexisting_private_target_is_never_created_or_deleted() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::admission_status_failure("has-session", 0, ""),
    );

    let error = discover(&host).expect_err("preexisting target must stop admission");

    assert_eq!(error.kind(), HostErrorKind::UnsupportedEnvironment);
    let calls = host.runner().all_calls();
    assert!(!calls.iter().any(|(_, args)| {
        args.iter().any(|argument| {
            matches!(
                argument.to_str(),
                Some("new-session" | "kill-session" | "kill-server")
            )
        })
    }));
}

#[test]
fn duplicate_creation_failure_never_grants_cleanup_authority() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::admission_status_failure("new-session", 1, "duplicate session"),
    );

    discover(&host).expect_err("duplicate creation must stop admission");

    assert!(!host.runner().all_calls().iter().any(|(_, args)| {
        args.iter()
            .any(|argument| matches!(argument.to_str(), Some("kill-session" | "kill-server")))
    }));
}

#[test]
fn discovery_decodes_length_prefixed_session_names_without_splitting_records() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(
            0,
            "4242\t$3\t1700000000\t1\t19\twork name\tand\nlines\n",
            "",
        ),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let snapshot = discover(&host).expect("discover length-prefixed session name");

    assert_eq!(snapshot.sessions()[0].name(), "work name\tand\nlines");
    let plan = host.attach_plan(snapshot.endpoint(), &snapshot.sessions()[0]);
    assert_eq!(plan.target_name(), "work name\tand\nlines");
    assert!(
        plan.args()
            .iter()
            .any(|argument| argument == "attach-session -E -t =$3")
    );
    assert!(
        !plan
            .args()
            .iter()
            .any(|argument| argument.to_string_lossy().contains("work name")),
        "the display name must not participate in attachment targeting"
    );
    assert!(host.runner().all_calls().iter().any(|(_, args)| {
        args.iter().any(|argument| argument == "list-sessions")
            && argument_after(args, "-F")
                == Some(
                    "#{pid}\t#{session_id}\t#{session_created}\t#{session_attached}\t#{n:session_name}\t#{session_name}",
                )
    }));
}

#[test]
fn kill_capture_matches_format_shaped_names_without_targeting_them() {
    let name = "work#(touch /tmp/ghosthub-owned)\nand-more";
    let inventory = format!("4242\t$3\t1700000000\t0\t{}\t{name}\n", name.len());
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, &inventory, ""),
        instance_output(),
        instance_output(),
        output(0, &inventory, ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );
    let snapshot = discover(&host).expect("discover format-shaped session name");

    let target = host
        .capture_live_session(
            snapshot.endpoint(),
            snapshot.runtime(),
            name,
            &CancellationToken::new(),
        )
        .expect("capture identity from decoded inventory");

    assert_eq!(target.name(), name);
    assert_eq!(target.identity().session_id(), "$3");
    assert!(host.runner().all_calls().iter().all(|(_, args)| {
        args.iter()
            .all(|argument| !argument.to_string_lossy().contains("#("))
    }));
}

#[test]
fn attach_plan_targets_the_fresh_stable_session_id() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t9\twork name\n", ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );
    let snapshot = discover(&host).expect("discover sessions");

    let plan = host.attach_plan(
        snapshot.endpoint(),
        snapshot.sessions().first().expect("one session"),
    );
    let args = plan
        .args()
        .iter()
        .map(|value| value.to_string_lossy().into_owned())
        .collect::<Vec<_>>();

    assert_eq!(plan.program(), OsStr::new(r"C:\Windows\System32\wsl.exe"));
    assert_eq!(
        args,
        vec![
            "--distribution",
            "Ubuntu",
            "--exec",
            "/usr/bin/env",
            "-u",
            "TMUX",
            "-u",
            "TMUX_PANE",
            "-u",
            "TMUX_TMPDIR",
            "TERM=xterm-256color",
            "/usr/bin/tmux",
            "if-shell",
            "-F",
            "-t",
            "=$3:",
            "#{&&:#{==:#{pid},4242},#{&&:#{==:#{session_id},$3},#{==:#{session_created},1700000000}}}",
            "attach-session -E -t =$3",
            "display-message -p __ghosthub_attach_identity_mismatch_v1__",
        ]
    );
    assert!(!args.iter().any(|argument| argument == "new-session"));
}

#[test]
fn kill_authority_comes_from_a_fresh_query_and_targets_stable_identity() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
        instance_output(),
        output(0, "", ""),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );
    let snapshot = discover(&host).expect("discover sessions");

    let target = host
        .capture_live_session(
            snapshot.endpoint(),
            snapshot.runtime(),
            "work",
            &CancellationToken::new(),
        )
        .expect("capture fresh kill authority");
    host.kill_live_session(&target, &CancellationToken::new())
        .expect("kill confirmed identity");

    assert_eq!(target.identity().server_pid(), 4242);
    assert_eq!(target.identity().session_id(), "$3");
    assert_eq!(target.identity().created_at(), 1_700_000_000);
    let calls = host.runner().calls();
    let identity_call = calls
        .iter()
        .filter(|(_, args)| args.iter().any(|argument| argument == "list-sessions"))
        .nth(1)
        .expect("fresh all-session identity query");
    assert_eq!(argument_after(&identity_call.1, "-t"), None);
    let kill_call = calls
        .iter()
        .find(|(_, args)| args.iter().any(|argument| argument == "if-shell"))
        .expect("conditional kill command");
    assert_eq!(argument_after(&kill_call.1, "-t"), Some("=$3:"));
    assert!(kill_call.1.iter().any(|argument| {
        argument
            == "#{&&:#{==:#{pid},4242},#{&&:#{==:#{session_id},$3},#{==:#{session_created},1700000000}}}"
    }));
    assert!(
        kill_call
            .1
            .iter()
            .any(|argument| argument == "kill-session -t =$3")
    );
}

#[test]
fn replaced_session_is_not_killed_after_confirmation() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
        instance_output(),
        output(0, "__ghosthub_kill_identity_mismatch_v1__\n", ""),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );
    let snapshot = discover(&host).expect("discover sessions");
    let target = host
        .capture_live_session(
            snapshot.endpoint(),
            snapshot.runtime(),
            "work",
            &CancellationToken::new(),
        )
        .expect("capture fresh kill authority");

    let error = host
        .kill_live_session(&target, &CancellationToken::new())
        .expect_err("identity mismatch must refuse the kill");

    assert!(error.to_string().contains("replaced after confirmation"));
}

#[test]
fn missing_stable_target_detects_a_same_named_replacement_from_inventory() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
        instance_output(),
        output(1, "", "can't find session: $3"),
        output(0, "4242\t$4\t1700000001\t0\t4\twork\n", ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );
    let snapshot = discover(&host).expect("discover sessions");
    let target = host
        .capture_live_session(
            snapshot.endpoint(),
            snapshot.runtime(),
            "work",
            &CancellationToken::new(),
        )
        .expect("capture fresh kill authority");

    let error = host
        .kill_live_session(&target, &CancellationToken::new())
        .expect_err("same-named replacement must be reported");

    assert!(error.to_string().contains("replaced after confirmation"));
    let calls = host.runner().calls();
    let replacement_query = calls
        .iter()
        .filter(|(_, args)| args.iter().any(|argument| argument == "list-sessions"))
        .nth(2)
        .expect("replacement inventory query");
    assert_eq!(argument_after(&replacement_query.1, "-t"), None);
    assert!(
        replacement_query
            .1
            .iter()
            .all(|argument| argument != "work")
    );
}

#[test]
fn configured_socket_directory_is_explicit_environment() {
    let config = WslConfig::configured(
        Some("Ubuntu".to_owned()),
        "/opt/tmux/bin/tmux",
        Some("/run/user/1000".to_owned()),
    )
    .expect("valid config");
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
    ]);
    let host = test_host(config, runner);
    let snapshot = discover(&host).expect("discover sessions");
    let plan = host.attach_plan(
        snapshot.endpoint(),
        snapshot.sessions().first().expect("one session"),
    );
    let args = plan
        .args()
        .iter()
        .map(|value| value.to_string_lossy().into_owned())
        .collect::<Vec<_>>();

    assert!(args.iter().any(|arg| arg == "TMUX_TMPDIR=/run/user/1000"));
    assert!(args.iter().any(|arg| arg == "/opt/tmux/bin/tmux"));
    assert!(has_tmux_environment_scrub(plan.args()));
}

#[test]
fn discovery_scrubs_inherited_tmux_client_environment() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\t0\t4\twork\n", ""),
        instance_output(),
    ]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    discover(&host).expect("discover sessions");

    assert!(host.runner().calls().iter().any(|(_, args)| {
        args.iter().any(|argument| argument == "list-sessions") && has_tmux_environment_scrub(args)
    }));
}

#[test]
fn malformed_inventory_is_classified() {
    let runner = RecordingRunner::new(vec![instance_output(), output(0, "not-five-fields\n", "")]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let error = discover(&host).expect_err("malformed output must fail");

    assert_eq!(error.kind(), HostErrorKind::MalformedOutput);
}

#[test]
fn missing_tmux_binary_is_classified() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(127, "", "/usr/bin/env: '/missing/tmux': No such file\n"),
    ]);
    let host = test_host(
        WslConfig::configured(Some("Ubuntu".to_owned()), "/missing/tmux", None)
            .expect("valid config"),
        runner,
    );

    let error = discover(&host).expect_err("missing binary must fail");

    assert_eq!(error.kind(), HostErrorKind::ExecutableNotFound);
    assert!(error.to_string().contains("/missing/tmux"));
}

#[test]
fn missing_tmux_binary_during_admission_is_classified_before_capability_checks() {
    let host = test_host(
        WslConfig::configured(Some("Ubuntu".to_owned()), "/missing/tmux", None)
            .expect("valid config"),
        RecordingRunner::missing_admission_executable("-V"),
    );

    let error = host
        .discover(host.runner())
        .expect_err("missing binary must fail admission");

    assert_eq!(error.kind(), HostErrorKind::ExecutableNotFound);
    assert!(error.to_string().contains("/missing/tmux"));
}

#[test]
fn permission_failure_during_admission_is_classified_before_capability_checks() {
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        RecordingRunner::admission_status_failure("show-environment", 1, "permission denied"),
    );

    let error = host
        .discover(host.runner())
        .expect_err("permission failure must fail admission");

    assert_eq!(error.kind(), HostErrorKind::PermissionDenied);
}

#[test]
fn rejects_wsl1_runtime_identity() {
    let runner = RecordingRunner::new(vec![output(
        0,
        "Linux version 4.4.0-microsoft-standard\n\
         65c18272-9676-4d59-9f67-ff4556cd1601\n\
         1 (init) S 0 1 1 0 -1 0 1 2 3 4 5 6 7 8 9 10 11 12 42 15\n",
        "",
    )]);
    let host = test_host(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let error = discover(&host).expect_err("WSL1 must be rejected");

    assert_eq!(error.kind(), HostErrorKind::UnsupportedEnvironment);
    let calls = host.runner().all_calls();
    assert_eq!(calls.len(), 1, "runtime validation must precede admission");
    assert!(
        !calls[0]
            .1
            .iter()
            .any(|argument| matches!(argument.to_str(), Some("/usr/bin/tmux" | "/usr/bin/mkdir")))
    );
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct WslFixture {
    schema_version: u32,
    executable_platform: ExecutablePlatform,
    distro: String,
    tmux_path: String,
    tmux_tmpdir: Option<String>,
    instance_output: String,
    inventory_output: String,
    expected: ExpectedSession,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExpectedSession {
    server_pid: u32,
    session_id: String,
    created_at: u64,
    name: String,
    attached_clients: u32,
}

#[test]
fn consumes_the_windows_hosted_posix_wsl_contract() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("contracts");
    let manifest = Manifest::load(&root).expect("load contract manifest");
    let mut run = manifest.suite("wsl-host", &[PlatformTag::Windows]);
    let path = run
        .consume("mux.wsl-tmux.host.v1")
        .expect("consume WSL host fixture");
    let fixture: WslFixture =
        serde_json::from_str(&fs::read_to_string(path).expect("read fixture"))
            .expect("parse strict WSL fixture");
    assert_eq!(fixture.schema_version, 1);
    assert_eq!(fixture.executable_platform, ExecutablePlatform::Posix);

    let runner = RecordingRunner::new(vec![
        output(0, &fixture.instance_output, ""),
        output(0, &fixture.inventory_output, ""),
        output(0, &fixture.instance_output, ""),
    ]);
    let host = test_host(
        WslConfig::configured(Some(fixture.distro), fixture.tmux_path, fixture.tmux_tmpdir)
            .expect("valid fixture config"),
        runner,
    );
    let snapshot = discover(&host).expect("discover fixture");
    let session = snapshot.sessions().first().expect("fixture session");

    assert_eq!(session.identity().server_pid(), fixture.expected.server_pid);
    assert_eq!(session.identity().session_id(), fixture.expected.session_id);
    assert_eq!(session.identity().created_at(), fixture.expected.created_at);
    assert_eq!(session.name(), fixture.expected.name);
    assert_eq!(
        session.attached_clients(),
        fixture.expected.attached_clients
    );
    run.finish().expect("consume all WSL host fixtures");
}
