use std::collections::VecDeque;
use std::ffi::{OsStr, OsString};
use std::fs;
use std::io;
use std::path::Path;
use std::sync::Mutex;

use contracts::{Manifest, PlatformTag};
use host::{CommandOutput, CommandRunner, HostErrorKind, WslConfig, WslHost};
use serde::Deserialize;
use session::ExecutablePlatform;

#[derive(Debug)]
struct RecordingRunner {
    outputs: Mutex<VecDeque<io::Result<CommandOutput>>>,
    calls: Mutex<Vec<(OsString, Vec<OsString>)>>,
}

impl RecordingRunner {
    fn new(outputs: Vec<CommandOutput>) -> Self {
        Self {
            outputs: Mutex::new(outputs.into_iter().map(Ok).collect()),
            calls: Mutex::new(Vec::new()),
        }
    }

    fn calls(&self) -> Vec<(OsString, Vec<OsString>)> {
        self.calls.lock().expect("calls lock").clone()
    }
}

impl CommandRunner for RecordingRunner {
    fn run(&self, program: &OsStr, args: &[OsString]) -> io::Result<CommandOutput> {
        self.calls
            .lock()
            .expect("calls lock")
            .push((program.to_owned(), args.to_vec()));
        self.outputs
            .lock()
            .expect("outputs lock")
            .pop_front()
            .expect("scripted command output")
    }
}

fn output(status: i32, stdout: &str, stderr: &str) -> CommandOutput {
    CommandOutput {
        status,
        stdout: stdout.as_bytes().to_vec(),
        stderr: stderr.as_bytes().to_vec(),
    }
}

fn instance_output() -> CommandOutput {
    output(
        0,
        "Linux version 6.6.114.1-microsoft-standard-WSL2\n\
         65c18272-9676-4d59-9f67-ff4556cd1601\n\
         1 (systemd) S 0 1 1 0 -1 4194560 1 2 3 4 5 6 7 8 9 10 11 12 987654 15\n",
        "",
    )
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
    ]);
    let host = WslHost::new(WslConfig::default(), runner);

    let snapshot = host.discover().expect("no server is not an error");

    assert_eq!(snapshot.endpoint().distro(), "Ubuntu");
    assert!(snapshot.sessions().is_empty());
    assert_eq!(snapshot.runtime().init_start_ticks(), 987_654);
    assert_eq!(host.runner().calls().len(), 3);
}

#[test]
fn discovers_identity_in_one_tmux_crossing() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\twork name\t1\n", ""),
    ]);
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let snapshot = host.discover().expect("discover sessions");
    let session = snapshot.sessions().first().expect("one session");

    assert_eq!(session.name(), "work name");
    assert_eq!(session.identity().server_pid(), 4242);
    assert_eq!(session.identity().session_id(), "$3");
    assert_eq!(session.identity().created_at(), 1_700_000_000);
    assert_eq!(session.attached_clients(), 1);
    assert_eq!(host.runner().calls().len(), 2);
}

#[test]
fn attach_plan_preserves_exact_name_as_one_argument() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(0, "4242\t$3\t1700000000\twork name\t0\n", ""),
    ]);
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );
    let snapshot = host.discover().expect("discover sessions");

    let plan = host
        .attach_plan(
            snapshot.endpoint(),
            snapshot.sessions().first().expect("one session"),
        )
        .expect("build attach plan");
    let args = plan
        .args()
        .iter()
        .map(|value| value.to_string_lossy().into_owned())
        .collect::<Vec<_>>();

    assert_eq!(plan.program(), OsStr::new("wsl.exe"));
    assert_eq!(
        args,
        vec![
            "--distribution",
            "Ubuntu",
            "--exec",
            "/usr/bin/env",
            "TERM=xterm-256color",
            "/usr/bin/tmux",
            "attach-session",
            "-E",
            "-t",
            "=work name",
        ]
    );
    assert!(!args.iter().any(|argument| argument == "new-session"));
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
        output(0, "4242\t$3\t1700000000\twork\t0\n", ""),
    ]);
    let host = WslHost::new(config, runner);
    let snapshot = host.discover().expect("discover sessions");
    let plan = host
        .attach_plan(
            snapshot.endpoint(),
            snapshot.sessions().first().expect("one session"),
        )
        .expect("build attach plan");
    let args = plan
        .args()
        .iter()
        .map(|value| value.to_string_lossy().into_owned())
        .collect::<Vec<_>>();

    assert!(args.iter().any(|arg| arg == "TMUX_TMPDIR=/run/user/1000"));
    assert!(args.iter().any(|arg| arg == "/opt/tmux/bin/tmux"));
}

#[test]
fn malformed_inventory_is_classified() {
    let runner = RecordingRunner::new(vec![instance_output(), output(0, "not-five-fields\n", "")]);
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let error = host.discover().expect_err("malformed output must fail");

    assert_eq!(error.kind(), HostErrorKind::MalformedOutput);
}

#[test]
fn missing_tmux_binary_is_classified() {
    let runner = RecordingRunner::new(vec![
        instance_output(),
        output(127, "", "/usr/bin/env: '/missing/tmux': No such file\n"),
    ]);
    let host = WslHost::new(
        WslConfig::configured(Some("Ubuntu".to_owned()), "/missing/tmux", None)
            .expect("valid config"),
        runner,
    );

    let error = host.discover().expect_err("missing binary must fail");

    assert_eq!(error.kind(), HostErrorKind::ExecutableNotFound);
    assert!(error.to_string().contains("/missing/tmux"));
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
    let host = WslHost::new(
        WslConfig::with_distro("Ubuntu").expect("valid config"),
        runner,
    );

    let error = host.discover().expect_err("WSL1 must be rejected");

    assert_eq!(error.kind(), HostErrorKind::UnsupportedEnvironment);
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
    ]);
    let host = WslHost::new(
        WslConfig::configured(Some(fixture.distro), fixture.tmux_path, fixture.tmux_tmpdir)
            .expect("valid fixture config"),
        runner,
    );
    let snapshot = host.discover().expect("discover fixture");
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
