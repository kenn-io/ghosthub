use std::ffi::{OsStr, OsString};
use std::io;
use std::sync::{Arc, Mutex};

use super::*;
use crate::remote::{RemoteTmuxConfig, tests::controller_lease};
use crate::{CommandPrefix, HerdrInventory, KwtWorktreeCreate, SshTarget, ZellijInventory};

struct KwtRunner {
    mutation: CommandOutput,
    deadlines: Mutex<Vec<Duration>>,
}

impl CommandRunner for KwtRunner {
    fn run(
        &self,
        _program: &OsStr,
        args: &[OsString],
        _cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput> {
        let command = args.last().unwrap().to_str().unwrap();
        let marker = command
            .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
            .find(|word| word.starts_with("GHOSTHUB_KWT_") && word.contains("_BEGIN_"))
            .expect("framed KWT command");
        let end = marker.replace("_BEGIN_", "_END_");
        let (status, stdout, stderr) = if marker.starts_with("GHOSTHUB_KWT_TARGET_") {
            (
                0,
                b"Linux\nx86_64\n/home/fixture\n".as_slice(),
                b"".as_slice(),
            )
        } else if marker.starts_with("GHOSTHUB_KWT_READY_") {
            (0, b"".as_slice(), b"".as_slice())
        } else {
            assert!(marker.starts_with("GHOSTHUB_KWT_COMMAND_"));
            self.deadlines.lock().unwrap().push(timeout);
            if command.contains("--no-launch") {
                (
                    self.mutation.status,
                    self.mutation.stdout.as_slice(),
                    self.mutation.stderr.as_slice(),
                )
            } else {
                assert!(command.contains("branches") && command.contains("--json"));
                (0, b"[]\n".as_slice(), b"".as_slice())
            }
        };
        Ok(CommandOutput {
            status: 0,
            stdout: [
                format!("{marker}\n").as_bytes(),
                stdout,
                format!("{end}_STATUS_{status}\n{end}\n").as_bytes(),
            ]
            .concat(),
            stderr: [
                format!("{marker}\n").as_bytes(),
                stderr,
                format!("{end}\n").as_bytes(),
            ]
            .concat(),
        })
    }
}

fn fixture(
    output: CommandOutput,
) -> (
    RemoteTmuxHost<Arc<KwtRunner>>,
    RemoteTmuxSnapshot,
    Arc<KwtRunner>,
) {
    let config = RemoteTmuxConfig::new(
        "ssh:test",
        "Test",
        SshTarget::new("host-alias", None, None).unwrap(),
        "",
        None,
    )
    .unwrap()
    .with_kwt_bundles(vec![(
        RemoteKwtTarget::LinuxAmd64,
        KwtBundle::new("a".repeat(40), "b".repeat(64), vec![1_u8]).unwrap(),
    )]);
    let runner = Arc::new(KwtRunner {
        mutation: output,
        deadlines: Mutex::default(),
    });
    let host = RemoteTmuxHost::with_commands(
        config,
        CommandPrefix::native("controller"),
        CommandPrefix::native("ssh"),
        Arc::clone(&runner),
    );
    let snapshot = RemoteTmuxSnapshot {
        endpoint: "host-alias".to_owned(),
        route_identity: "a".repeat(64),
        lease_generation: 7,
        inventory_generation: 0,
        tmux_binary: None,
        tmux_diagnostic: None,
        sessions: Vec::new(),
        kwt_sessions: Vec::new(),
        kwt_tmux_diagnostic: None,
        herdr: HerdrInventory::Unavailable,
        zellij: ZellijInventory::Unavailable,
        lease: controller_lease(false),
    };
    (host, snapshot, runner)
}

fn creation() -> KwtWorktreeCreate {
    KwtWorktreeCreate::new(
        "/code/widget",
        "github.com/acme/widget",
        "registration",
        "feature/ready",
        None,
        true,
    )
}

#[test]
fn remote_creation_uses_a_mutation_deadline_while_branch_reads_stay_short() {
    let (host, snapshot, runner) = fixture(CommandOutput {
        status: 0,
        stdout: Vec::new(),
        stderr: Vec::new(),
    });
    let cancellation = CancellationToken::new();
    host.list_kwt_branches(&snapshot, "/code/widget", &cancellation)
        .unwrap();
    host.create_kwt_worktree(&snapshot, &creation(), &cancellation)
        .unwrap();
    assert_eq!(
        *runner.deadlines.lock().unwrap(),
        [Duration::from_secs(20), Duration::from_mins(5)]
    );
}

#[test]
fn remote_creation_preserves_structured_timeouts_without_retrying_add() {
    for stderr in [false, true] {
        for (code, kind) in [
            ("inventory_timeout", DiagnosticKind::Timeout),
            ("registration_changed", DiagnosticKind::Transport),
        ] {
            let failure = format!(r#"{{"error":{{"code":"{code}","message":"creation result uncertain","retryable":true}}}}"#).into_bytes();
            let (host, snapshot, runner) = fixture(CommandOutput {
                status: 1,
                stdout: if stderr { Vec::new() } else { failure.clone() },
                stderr: if stderr { failure } else { Vec::new() },
            });
            let error = host
                .create_kwt_worktree(&snapshot, &creation(), &CancellationToken::new())
                .unwrap_err();
            assert_eq!(error.kind(), kind, "{code}, stderr={stderr}");
            assert!(error.to_string().contains("creation result uncertain"));
            assert_eq!(
                runner.deadlines.lock().unwrap().len(),
                1,
                "never replay a mutation"
            );
        }
    }
}
