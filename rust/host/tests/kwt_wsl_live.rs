use std::ffi::OsStr;
use std::fs;
use std::io::{Read, Write};
use std::process::{Command, Output};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use host::{
    AttachTerm, CancellationToken, KwtBundle, KwtWorktreeCreate, KwtWorktreeOpen, StdCommandRunner,
    SystemWslPresence, WslConfig, WslEndpoint, WslExecutable, WslHost, WslPresence,
};
use portable_pty::{CommandBuilder, PtySize, native_pty_system};

const READY_TIMEOUT: Duration = Duration::from_secs(20);

#[test]
#[ignore = "requires Windows, WSL2, tmux, git, and a staged pinned Linux KWT helper"]
#[allow(
    clippy::too_many_lines,
    reason = "the live test keeps one isolated worktree lifecycle and its cleanup in order"
)]
fn pinned_helper_honors_the_worktree_lifecycle_contract() {
    let bundle_path = std::env::var_os("GHOSTHUB_KWT_BUNDLE_TEST")
        .expect("set GHOSTHUB_KWT_BUNDLE_TEST to the staged Linux helper");
    let digest = std::env::var("GHOSTHUB_KWT_SHA256_TEST")
        .expect("set GHOSTHUB_KWT_SHA256_TEST to its lowercase digest");
    let repo = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(std::path::Path::parent)
        .expect("host crate is nested under rust/");
    let revision = fs::read_to_string(repo.join("KWT_REVISION"))
        .expect("read KWT revision")
        .trim()
        .to_owned();
    let bundle = KwtBundle::new(
        revision,
        digest,
        Arc::<[u8]>::from(fs::read(&bundle_path).expect("read staged helper")),
    )
    .expect("valid helper bundle");
    let executable = SystemWslPresence
        .resolve()
        .expect("resolve WSL presence")
        .expect("WSL is installed");
    let nonce = format!(
        "{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock is after Unix epoch")
            .as_nanos()
    );
    let root = format!("/tmp/ghosthub-kwt-live-{nonce}");
    let kwt_home = format!("{root}/home");
    let tmux_tmpdir = format!("{root}/tmux");
    let project_path = format!("{root}/repo");
    let branch = format!("ghosthub-live-{nonce}");
    let host = WslHost::new(
        WslConfig::configured(None, "/usr/bin/tmux", Some(tmux_tmpdir.clone()))
            .expect("valid isolated WSL config")
            .with_kwt_bundle(bundle)
            .with_kwt_home_for_tests(&kwt_home),
        StdCommandRunner,
        executable.clone(),
    );
    let cancellation = CancellationToken::new();

    let initial = host
        .discover_kwt_current(&cancellation)
        .expect("install the pinned helper and read isolated KWT inventory");
    let endpoint = initial.endpoint().clone();
    let runtime = initial.runtime().clone();
    let helper_path = windows_path_in_wsl(&executable, &endpoint, &bundle_path);
    let _cleanup = TestEnvironment {
        executable: executable.clone(),
        endpoint: endpoint.clone(),
        root: root.clone(),
        kwt_home: kwt_home.clone(),
        tmux_tmpdir: tmux_tmpdir.clone(),
        helper_path,
    };

    run_wsl_ok(
        &executable,
        &endpoint,
        [
            "/usr/bin/mkdir",
            "-p",
            "--",
            tmux_tmpdir.as_str(),
            project_path.as_str(),
        ],
    );
    run_wsl_ok(
        &executable,
        &endpoint,
        [
            "/usr/bin/git",
            "-C",
            project_path.as_str(),
            "init",
            "-b",
            "main",
        ],
    );
    run_wsl_ok(
        &executable,
        &endpoint,
        [
            "/usr/bin/git",
            "-C",
            project_path.as_str(),
            "config",
            "user.email",
            "ghosthub-live@example.invalid",
        ],
    );
    run_wsl_ok(
        &executable,
        &endpoint,
        [
            "/usr/bin/git",
            "-C",
            project_path.as_str(),
            "config",
            "user.name",
            "Ghosthub Live Test",
        ],
    );
    run_wsl_ok(
        &executable,
        &endpoint,
        [
            "/usr/bin/git",
            "-C",
            project_path.as_str(),
            "commit",
            "--allow-empty",
            "-m",
            "initial",
        ],
    );

    let registered = host
        .register_kwt_project(&endpoint, &runtime, &project_path, &cancellation)
        .expect("register isolated project through the pinned helper");
    host.create_kwt_worktree(
        &endpoint,
        &runtime,
        &KwtWorktreeCreate::new(
            &project_path,
            registered.repository(),
            registered.registration_fingerprint(),
            &branch,
            None,
            true,
        ),
        &cancellation,
    )
    .expect("create a no-launch worktree through the pinned helper");
    assert!(
        !host
            .session_is_running(&endpoint, &runtime, &branch, &cancellation)
            .expect("query isolated tmux inventory"),
        "--no-launch creation must not create a tmux session"
    );

    let inventory = host
        .discover_kwt_current(&cancellation)
        .expect("read the created worktree")
        .inventory()
        .expect("KWT inventory is available")
        .clone();
    let project = inventory
        .projects()
        .iter()
        .find(|entry| entry.project().path() == project_path)
        .expect("registered project is present");
    let worktree = project
        .worktrees()
        .iter()
        .find(|worktree| worktree.branch() == branch)
        .expect("created worktree is present");
    let generation = worktree
        .generation()
        .expect("created worktree has a generation");
    let open = KwtWorktreeOpen::new(
        worktree.path(),
        worktree.repository(),
        project.project().registration_fingerprint(),
        generation,
        worktree.session_name(),
    );

    assert_guarded_open_rejected(
        &host,
        &endpoint,
        &runtime,
        &KwtWorktreeOpen::new(
            worktree.path(),
            worktree.repository(),
            "stale-registration",
            generation,
            worktree.session_name(),
        ),
        &cancellation,
    );
    assert_guarded_open_rejected(
        &host,
        &endpoint,
        &runtime,
        &KwtWorktreeOpen::new(
            worktree.path(),
            worktree.repository(),
            project.project().registration_fingerprint(),
            "00000000000000000000000000000000",
            worktree.session_name(),
        ),
        &cancellation,
    );

    let plan = host
        .kwt_repair_or_open_plan(&endpoint, &runtime, &open, AttachTerm::Xterm, &cancellation)
        .expect("build guarded repair/open plan");
    let pty = native_pty_system()
        .openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .expect("open ConPTY for the real KWT client");
    let mut reader = pty
        .master
        .try_clone_reader()
        .expect("clone KWT client output reader");
    let mut writer = pty
        .master
        .take_writer()
        .expect("take KWT client input writer");
    let client_output = Arc::new(Mutex::new(Vec::new()));
    let reader_output = Arc::clone(&client_output);
    let reader_thread = thread::spawn(move || {
        let mut chunk = [0_u8; 1024];
        let mut query_scan = Vec::new();
        while let Ok(count) = reader.read(&mut chunk) {
            if count == 0 {
                break;
            }
            query_scan.extend_from_slice(&chunk[..count]);
            for _ in query_scan.windows(4).filter(|bytes| *bytes == b"\x1b[6n") {
                writer
                    .write_all(b"\x1b[1;1R")
                    .expect("answer terminal cursor-position query");
                writer.flush().expect("flush terminal response");
            }
            if query_scan.len() > 3 {
                query_scan.drain(..query_scan.len() - 3);
            }
            let mut output = reader_output.lock().expect("lock KWT client output");
            let remaining = 16 * 1024_usize - output.len().min(16 * 1024);
            output.extend_from_slice(&chunk[..count.min(remaining)]);
        }
    });
    let mut command = CommandBuilder::new(plan.program());
    command.args(plan.args());
    let mut child = pty
        .slave
        .spawn_command(command)
        .expect("spawn the real KWT client through ConPTY");
    drop(pty.slave);

    let identity = wait_for_exact_client(
        &host,
        &endpoint,
        &runtime,
        plan.readiness_path(),
        &cancellation,
        &client_output,
    );
    let target = host
        .capture_live_session(&endpoint, &runtime, worktree.session_name(), &cancellation)
        .expect("capture the exact live worktree session");
    assert_eq!(identity, *target.identity());

    let stale_remove = host.remove_kwt_worktree(
        &endpoint,
        &runtime,
        project_path.as_str(),
        worktree.path(),
        "00000000000000000000000000000000",
        worktree.session_name(),
        None,
        Some(&target),
        &cancellation,
    );
    assert!(
        stale_remove.is_err(),
        "a stale generation must not remove the worktree"
    );
    assert!(
        host.session_is_running(&endpoint, &runtime, worktree.session_name(), &cancellation,)
            .expect("query tmux after rejected removal"),
        "a rejected removal must preserve the exact session"
    );

    host.remove_kwt_worktree(
        &endpoint,
        &runtime,
        project_path.as_str(),
        worktree.path(),
        generation,
        worktree.session_name(),
        None,
        Some(&target),
        &cancellation,
    )
    .expect("atomically stop the exact session and remove the worktree");
    assert!(
        !host
            .session_is_running(&endpoint, &runtime, worktree.session_name(), &cancellation,)
            .expect("query tmux after guarded removal"),
        "guarded removal must terminate the confirmed session"
    );
    let final_inventory = host
        .discover_kwt_current(&cancellation)
        .expect("reconcile KWT after guarded removal")
        .inventory()
        .expect("KWT inventory remains available")
        .clone();
    assert!(final_inventory.projects().iter().all(|entry| {
        entry
            .worktrees()
            .iter()
            .all(|candidate| candidate.path() != worktree.path())
    }));

    wait_for_child_exit(&mut *child);
    drop(pty.master);
    reader_thread.join().expect("join KWT client output reader");
    host.remove_kwt_client_readiness(&endpoint, plan.readiness_path(), &cancellation);
}

fn assert_guarded_open_rejected(
    host: &WslHost<StdCommandRunner>,
    endpoint: &WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    request: &KwtWorktreeOpen,
    cancellation: &CancellationToken,
) {
    let plan = host
        .kwt_repair_or_open_plan(endpoint, runtime, request, AttachTerm::Xterm, cancellation)
        .expect("build stale guarded-open plan");
    let output = Command::new(plan.program())
        .args(plan.args())
        .output()
        .expect("run stale guarded-open plan");
    host.remove_kwt_client_readiness(endpoint, plan.readiness_path(), cancellation);
    assert!(
        !output.status.success(),
        "stale guarded-open authority must be rejected"
    );
    assert!(
        !host
            .session_is_running(endpoint, runtime, request.session_name(), cancellation)
            .expect("query tmux after rejected guarded open"),
        "rejected guarded-open authority must not create or attach a session"
    );
}

fn wait_for_exact_client(
    host: &WslHost<StdCommandRunner>,
    endpoint: &WslEndpoint,
    runtime: &host::WslRuntimeIdentity,
    readiness_path: &str,
    cancellation: &CancellationToken,
    output: &Mutex<Vec<u8>>,
) -> session::SessionIdentity {
    let deadline = Instant::now() + READY_TIMEOUT;
    loop {
        if let Some(identity) = host
            .kwt_client_session_identity(endpoint, runtime, readiness_path, cancellation)
            .expect("query exact KWT client readiness")
        {
            return identity;
        }
        if Instant::now() >= deadline {
            let output = output.lock().expect("lock KWT client output").clone();
            panic!(
                "KWT client did not attach before the deadline; output: {}",
                String::from_utf8_lossy(&output)
            );
        }
        thread::sleep(Duration::from_millis(50));
    }
}

fn wait_for_child_exit(child: &mut dyn portable_pty::Child) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if child.try_wait().expect("poll KWT client").is_some() {
            return;
        }
        if Instant::now() >= deadline {
            child.kill().expect("terminate lingering KWT client");
            child.wait().expect("reap lingering KWT client");
            return;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

fn windows_path_in_wsl(executable: &WslExecutable, endpoint: &WslEndpoint, path: &OsStr) -> String {
    let output = run_wsl(
        executable,
        endpoint,
        [OsStr::new("/usr/bin/wslpath"), OsStr::new("-a"), path],
    );
    assert!(
        output.status.success(),
        "wslpath failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("wslpath emits UTF-8")
        .trim()
        .to_owned()
}

fn run_wsl_ok<I, S>(executable: &WslExecutable, endpoint: &WslEndpoint, args: I)
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    let output = run_wsl(executable, endpoint, args);
    assert!(
        output.status.success(),
        "WSL command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

fn run_wsl<I, S>(executable: &WslExecutable, endpoint: &WslEndpoint, args: I) -> Output
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    Command::new(executable.as_os_str())
        .args(["--distribution", endpoint.distro(), "--exec"])
        .args(args)
        .output()
        .expect("run WSL command")
}

struct TestEnvironment {
    executable: WslExecutable,
    endpoint: WslEndpoint,
    root: String,
    kwt_home: String,
    tmux_tmpdir: String,
    helper_path: String,
}

impl Drop for TestEnvironment {
    fn drop(&mut self) {
        let _ = run_wsl(
            &self.executable,
            &self.endpoint,
            [
                "/usr/bin/env",
                &format!("KWT_HOME={}", self.kwt_home),
                self.helper_path.as_str(),
                "daemon",
                "stop",
            ],
        );
        let _ = run_wsl(
            &self.executable,
            &self.endpoint,
            [
                "/usr/bin/env",
                "-u",
                "TMUX",
                "-u",
                "TMUX_PANE",
                "-u",
                "TMUX_TMPDIR",
                &format!("TMUX_TMPDIR={}", self.tmux_tmpdir),
                "/usr/bin/tmux",
                "-f",
                "/dev/null",
                "kill-server",
            ],
        );
        if self.root.starts_with("/tmp/ghosthub-kwt-live-") {
            let _ = run_wsl(
                &self.executable,
                &self.endpoint,
                ["/usr/bin/rm", "-rf", "--", self.root.as_str()],
            );
        }
    }
}
