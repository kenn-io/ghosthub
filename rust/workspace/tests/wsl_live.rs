#![cfg(windows)]

use std::ffi::OsStr;
use std::process::{Command, Output};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use config::TerminalAppearance;
use host::WslConfig;
use workspace::{
    KeyInput, Modifiers, NamedKey, SessionSelection, Workspace, WorkspaceContent, WorkspaceEvent,
};

struct IsolatedServer {
    tmpdir: String,
}

static WSL_LIVE: Mutex<()> = Mutex::new(());

#[test]
fn isolated_namespace_includes_a_cross_process_nonce() {
    assert_eq!(isolated_tmpdir("attach", 42, 100), "/tmp/ghw-2a-64-attach");
}

impl IsolatedServer {
    fn start(label: &str) -> Self {
        let server = Self::empty(label);
        server.run_tmux(["new-session", "-d", "-s", "workspace-live"]);
        let socket = server.run_tmux(["display-message", "-p", "#{socket_path}"]);
        let socket = String::from_utf8(socket.stdout).expect("UTF-8 tmux socket path");
        assert!(
            socket.trim().starts_with(&format!("{}/", server.tmpdir)),
            "test tmux escaped its isolated directory: {socket:?}"
        );
        server
    }

    fn empty(label: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system time")
            .as_nanos();
        let tmpdir = isolated_tmpdir(label, std::process::id(), nonce);
        assert!(tmpdir.starts_with("/tmp/ghw-"));
        let mkdir = Command::new("wsl.exe")
            .args(["--exec", "/usr/bin/mkdir", "-p", "--", &tmpdir])
            .output()
            .expect("create isolated tmux directory");
        assert!(
            mkdir.status.success(),
            "create isolated tmux directory: {}",
            String::from_utf8_lossy(&mkdir.stderr)
        );
        Self { tmpdir }
    }

    fn run_tmux<I, S>(&self, args: I) -> Output
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let mut command = Command::new("wsl.exe");
        command.args([
            "--exec",
            "/usr/bin/env",
            &format!("TMUX_TMPDIR={}", self.tmpdir),
            "/usr/bin/tmux",
            "-f",
            "/dev/null",
        ]);
        command.args(args);
        let output = command.output().expect("run isolated WSL tmux command");
        assert!(
            output.status.success(),
            "isolated tmux failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        output
    }

    fn identity(&self) -> String {
        let output = self.run_tmux([
            "list-sessions",
            "-F",
            "#{pid}:#{session_id}:#{session_created}",
        ]);
        String::from_utf8(output.stdout)
            .expect("UTF-8 tmux identity")
            .trim()
            .to_owned()
    }

    fn has_session(&self, name: &str) -> bool {
        let output = Command::new("wsl.exe")
            .args([
                "--exec",
                "/usr/bin/env",
                &format!("TMUX_TMPDIR={}", self.tmpdir),
                "/usr/bin/tmux",
                "-f",
                "/dev/null",
                "has-session",
                "-t",
                &format!("={name}"),
            ])
            .output()
            .expect("query isolated WSL tmux session");
        output.status.success()
    }

    fn path_exists(path: &str) -> bool {
        Command::new("wsl.exe")
            .args(["--exec", "/usr/bin/test", "-e", path])
            .status()
            .expect("query isolated WSL path")
            .success()
    }
}

fn isolated_tmpdir(label: &str, process_id: u32, nonce: u128) -> String {
    format!("/tmp/ghw-{process_id:x}-{nonce:x}-{label}")
}

impl Drop for IsolatedServer {
    fn drop(&mut self) {
        if !self.tmpdir.starts_with("/tmp/ghw-") {
            return;
        }
        let _ignored = Command::new("wsl.exe")
            .args([
                "--exec",
                "/usr/bin/env",
                &format!("TMUX_TMPDIR={}", self.tmpdir),
                "/usr/bin/tmux",
                "-f",
                "/dev/null",
                "kill-server",
            ])
            .output();
        let _ignored = Command::new("wsl.exe")
            .args(["--exec", "/usr/bin/rm", "-rf", "--", &self.tmpdir])
            .output();
    }
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn discovers_attaches_renders_and_detaches_through_workspace() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("roundtrip");
    let identity = server.identity();
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.iter().any(|session| session.name() == "workspace-live")
            )
        },
        || workspace_diagnostic(&workspace),
    );
    let selection = session_selection(&workspace, "workspace-live");
    workspace.attach(&selection).expect("attach session");
    assert!(
        workspace.attach(&selection).is_err(),
        "a second presentation must lose the single-window reservation"
    );
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "workspace-live"
        )
    });
    workspace
        .send_key(KeyInput::text("echo workspace-ready", Modifiers::default()))
        .expect("send text");
    workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .expect("send enter");
    wait_until(|| terminal_contains(&workspace, "workspace-ready"));

    server.run_tmux(["set-buffer", "-w", "Hello"]);
    wait_until(|| {
        workspace.drain_events().0.into_iter().any(|event| {
            matches!(
                event,
                WorkspaceEvent::ClipboardWrite { text, primary: false } if text == "Hello"
            )
        })
    });

    workspace.detach();
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { .. }
        )
    });
    assert_eq!(server.identity(), identity);
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn creates_attaches_and_detaches_one_atomic_local_session() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::empty("create-once");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            let snapshot = workspace.snapshot();
            snapshot.hosts()[0].connection() == workspace::HostConnectionState::Ready
                && snapshot.hosts()[0].sessions().is_empty()
        },
        || workspace_diagnostic(&workspace),
    );
    let endpoint = workspace.snapshot().hosts()[0].endpoint().to_owned();
    workspace
        .create_session("wsl", &endpoint, "  created live  ")
        .expect("start one-shot local creation");
    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Terminal { session, .. } if session == "created live"
            )
        },
        || workspace_diagnostic(&workspace),
    );
    workspace
        .send_key(KeyInput::text("echo creation-clean", Modifiers::default()))
        .expect("send text through the created client");
    workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .expect("send enter through the created client");
    wait_until(|| terminal_contains(&workspace, "creation-clean"));
    assert!(
        !terminal_contains(&workspace, "__ghc_"),
        "the internal creation identity report must not reach the rendered surface"
    );
    let created_identity = server.run_tmux([
        "display-message",
        "-p",
        "-t",
        "=created live",
        "#{pid}:#{session_id}:#{session_created}",
    ]);
    let created_identity = String::from_utf8(created_identity.stdout)
        .expect("UTF-8 created identity")
        .trim()
        .to_owned();

    workspace.detach();
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "created live")
        )
    });
    let surviving_identity = server.run_tmux([
        "display-message",
        "-p",
        "-t",
        "=created live",
        "#{pid}:#{session_id}:#{session_created}",
    ]);
    assert_eq!(
        String::from_utf8(surviving_identity.stdout)
            .expect("UTF-8 surviving identity")
            .trim(),
        created_identity
    );
    assert!(
        workspace
            .create_session("wsl", &endpoint, "created live")
            .is_err(),
        "current inventory prevents an accidental duplicate create action"
    );
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn user_created_names_cannot_execute_tmux_format_jobs() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::empty("create-format-job");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());
    wait_until_with_diagnostic(
        || workspace.snapshot().hosts()[0].connection() == workspace::HostConnectionState::Ready,
        || workspace_diagnostic(&workspace),
    );
    let endpoint = workspace.snapshot().hosts()[0].endpoint().to_owned();
    let sentinel = format!("{}/owned", server.tmpdir);
    let hostile_name = format!("#(touch {sentinel})");
    assert!(hostile_name.chars().count() <= 100);

    let error = workspace
        .create_session("wsl", &endpoint, &hostile_name)
        .expect_err("tmux format syntax must not enter the creation plan");

    assert!(error.to_string().contains("number signs"));
    assert!(!IsolatedServer::path_exists(&sentinel));
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn creation_follows_the_client_identity_when_a_hook_renames_the_session() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("create-hook-rename");
    server.run_tmux([
        "set-hook",
        "-g",
        "after-new-session",
        "rename-session renamed-by-hook",
    ]);
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());
    wait_until_with_diagnostic(
        || workspace.snapshot().hosts()[0].connection() == workspace::HostConnectionState::Ready,
        || workspace_diagnostic(&workspace),
    );
    let endpoint = workspace.snapshot().hosts()[0].endpoint().to_owned();

    workspace
        .create_session("wsl", &endpoint, "requested-name")
        .expect("start renamed one-shot creation");
    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Terminal { session, .. } if session == "renamed-by-hook"
            )
        },
        || workspace_diagnostic(&workspace),
    );

    assert!(server.has_session("renamed-by-hook"));
    assert!(!server.has_session("requested-name"));
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn creation_race_attaches_the_exact_existing_session() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("create-race");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());
    wait_until_with_diagnostic(
        || workspace.snapshot().hosts()[0].connection() == workspace::HostConnectionState::Ready,
        || workspace_diagnostic(&workspace),
    );
    let endpoint = workspace.snapshot().hosts()[0].endpoint().to_owned();

    server.run_tmux(["new-session", "-d", "-s", "raced live"]);
    let before = server.run_tmux([
        "display-message",
        "-p",
        "-t",
        "=raced live",
        "#{pid}:#{session_id}:#{session_created}",
    ]);
    workspace
        .create_session("wsl", &endpoint, "raced live")
        .expect("the atomic action accepts a session absent from cached inventory");
    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Terminal { session, .. } if session == "raced live"
            )
        },
        || workspace_diagnostic(&workspace),
    );
    let after = server.run_tmux([
        "display-message",
        "-p",
        "-t",
        "=raced live",
        "#{pid}:#{session_id}:#{session_created}",
    ]);

    assert_eq!(
        after.stdout, before.stdout,
        "-A must preserve the raced identity"
    );
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn switches_between_discovered_sessions_without_destroying_either() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("switch");
    server.run_tmux(["new-session", "-d", "-s", "switch-live"]);
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.iter().any(|session| session.name() == "workspace-live")
                        && sessions.iter().any(|session| session.name() == "switch-live")
            )
        },
        || workspace_diagnostic(&workspace),
    );

    workspace
        .attach(&session_selection(&workspace, "workspace-live"))
        .expect("attach first session");
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "workspace-live"
        )
    });
    let first_presentation = active_presentation_id(&workspace);

    workspace
        .switch_session(&session_selection(&workspace, "switch-live"))
        .expect("begin session switch");
    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Terminal { session, .. } if session == "switch-live"
            )
        },
        || workspace_diagnostic(&workspace),
    );
    let second_presentation = active_presentation_id(&workspace);
    assert_retained(&workspace, "workspace-live");

    let sessions = server.run_tmux(["list-sessions", "-F", "#{session_name}:#{session_attached}"]);
    let sessions = String::from_utf8(sessions.stdout).expect("UTF-8 session inventory");
    assert!(sessions.lines().any(|line| line == "workspace-live:1"));
    assert!(sessions.lines().any(|line| line == "switch-live:1"));

    workspace
        .switch_session(&session_selection(&workspace, "workspace-live"))
        .expect("restore retained first presentation");
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Terminal {
            session,
            presentation_id,
            ..
        } if session == "workspace-live" && *presentation_id == first_presentation
    ));
    assert_retained(&workspace, "switch-live");

    workspace.detach();
    wait_until(|| {
        let sessions =
            server.run_tmux(["list-sessions", "-F", "#{session_name}:#{session_attached}"]);
        let sessions = String::from_utf8(sessions.stdout).expect("UTF-8 session inventory");
        sessions.lines().any(|line| line == "workspace-live:0")
            && sessions.lines().any(|line| line == "switch-live:1")
    });

    workspace
        .attach(&session_selection(&workspace, "switch-live"))
        .expect("restore retained second presentation");
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Terminal {
            session,
            presentation_id,
            ..
        } if session == "switch-live" && *presentation_id == second_presentation
    ));
    workspace.detach();
    wait_until(|| {
        let sessions =
            server.run_tmux(["list-sessions", "-F", "#{session_name}:#{session_attached}"]);
        let sessions = String::from_utf8(sessions.stdout).expect("UTF-8 session inventory");
        sessions.lines().any(|line| line == "workspace-live:0")
            && sessions.lines().any(|line| line == "switch-live:0")
    });
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "workspace-live")
                    && sessions.iter().any(|session| session.name() == "switch-live")
        )
    });
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn rename_during_switch_keeps_retained_navigation_consistent() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("rename-switch");
    server.run_tmux(["new-session", "-d", "-s", "switch-live"]);
    let workspace = start_workspace(&server);
    wait_for_sessions(&workspace, &["workspace-live", "switch-live"]);

    workspace
        .attach(&session_selection(&workspace, "workspace-live"))
        .expect("attach first session");
    wait_for_terminal(&workspace, "workspace-live");
    let switch_target = session_selection(&workspace, "switch-live");

    server.run_tmux(["rename-session", "-t", "=workspace-live", "renamed-live"]);
    workspace.refresh().expect("start rename refresh");
    workspace
        .switch_session(&switch_target)
        .expect("switch while rename refresh is active");
    wait_for_terminal(&workspace, "switch-live");
    wait_until(|| {
        let snapshot = workspace.snapshot();
        snapshot
            .hosts()
            .iter()
            .flat_map(workspace::HostItem::sessions)
            .any(|session| session.name() == "renamed-live")
            && snapshot
                .retained_selections()
                .iter()
                .any(|selection| selection.session() == "renamed-live")
            && !snapshot
                .retained_selections()
                .iter()
                .any(|selection| selection.session() == "workspace-live")
    });

    workspace
        .switch_session(&session_selection(&workspace, "renamed-live"))
        .expect("reactivate renamed retained presentation");
    wait_for_terminal(&workspace, "renamed-live");
    workspace
        .switch_session(&switch_target)
        .expect("retain renamed presentation again");
    wait_for_terminal(&workspace, "switch-live");

    let revision_before_exit = workspace.snapshot().revision();
    server.run_tmux(["kill-session", "-t", "=renamed-live"]);
    wait_until(|| {
        let _events = workspace.drain_events();
        let snapshot = workspace.snapshot();
        snapshot.revision() > revision_before_exit
            && !snapshot
                .retained_selections()
                .iter()
                .any(|selection| selection.session() == "renamed-live")
    });
    workspace.detach();
}

fn assert_retained(workspace: &Workspace, expected_session: &str) {
    assert!(
        workspace
            .snapshot()
            .retained_selections()
            .iter()
            .any(|selection| selection.session() == expected_session)
    );
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn failed_first_switch_restores_the_previous_presentation() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("switch-failure");
    server.run_tmux(["new-session", "-d", "-s", "switch-live"]);
    let workspace = start_workspace(&server);
    wait_for_sessions(&workspace, &["workspace-live", "switch-live"]);

    workspace
        .attach(&session_selection(&workspace, "workspace-live"))
        .expect("attach first session");
    wait_for_terminal(&workspace, "workspace-live");
    let presentation_id = active_presentation_id(&workspace);
    let missing = session_selection(&workspace, "switch-live");
    server.run_tmux(["kill-session", "-t", "=switch-live"]);

    workspace
        .switch_session(&missing)
        .expect("start guarded switch to stale inventory target");
    wait_for_terminal(&workspace, "workspace-live");
    assert_eq!(active_presentation_id(&workspace), presentation_id);
    assert!(
        workspace
            .snapshot()
            .notice()
            .is_some_and(|notice| notice.contains("no longer exists")),
        "restoring the prior terminal must preserve the switch failure diagnostic"
    );
    assert_session_attached(&server, "workspace-live", 1);
    workspace.detach();
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn failed_retained_activation_restores_the_previous_presentation() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("retained-failure");
    server.run_tmux(["new-session", "-d", "-s", "switch-live"]);
    let workspace = start_workspace(&server);
    wait_for_sessions(&workspace, &["workspace-live", "switch-live"]);

    workspace
        .attach(&session_selection(&workspace, "workspace-live"))
        .expect("attach first session");
    wait_for_terminal(&workspace, "workspace-live");
    workspace
        .switch_session(&session_selection(&workspace, "switch-live"))
        .expect("attach second session");
    wait_for_terminal(&workspace, "switch-live");
    let dead_target = session_selection(&workspace, "switch-live");
    workspace
        .switch_session(&session_selection(&workspace, "workspace-live"))
        .expect("restore first session");
    let presentation_id = active_presentation_id(&workspace);

    server.run_tmux(["kill-session", "-t", "=switch-live"]);
    thread::sleep(Duration::from_secs(2));
    assert!(workspace.switch_session(&dead_target).is_err());
    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Terminal { session, .. } if session == "workspace-live"
    ));
    assert_eq!(active_presentation_id(&workspace), presentation_id);
    assert_session_attached(&server, "workspace-live", 1);
    workspace.detach();
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn refuses_to_attach_when_the_discovered_session_was_replaced() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("stale-identity");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.iter().any(|session| session.name() == "workspace-live")
            )
        },
        || workspace_diagnostic(&workspace),
    );
    server.run_tmux(["kill-session", "-t", "=workspace-live"]);
    server.run_tmux(["new-session", "-d", "-s", "workspace-live"]);

    workspace
        .attach(&session_selection(&workspace, "workspace-live"))
        .expect("begin guarded attach");

    wait_until(|| {
        let snapshot = workspace.snapshot();
        matches!(
            snapshot.content(),
            WorkspaceContent::Shell | WorkspaceContent::Ready { .. }
        ) && snapshot.hosts()[0].connection() == workspace::HostConnectionState::Ready
            && snapshot.hosts()[0]
                .sessions()
                .iter()
                .any(|session| session.name() == "workspace-live")
            && snapshot
                .notice()
                .is_some_and(|notice| notice.contains("identity changed"))
    });
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn confirms_fresh_identity_and_never_kills_a_replacement() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("kill-confirmation");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.iter().any(|session| session.name() == "workspace-live")
            )
        },
        || workspace_diagnostic(&workspace),
    );
    let selection = session_selection(&workspace, "workspace-live");

    workspace
        .request_session_kill(&selection)
        .expect("begin live identity query");
    wait_until(|| workspace.session_kill_confirmation().is_some());
    workspace.cancel_session_kill();
    assert!(server.has_session("workspace-live"), "cancel must not kill");

    workspace
        .request_session_kill(&selection)
        .expect("begin second live identity query");
    wait_until(|| workspace.session_kill_confirmation().is_some());
    server.run_tmux(["kill-session", "-t", "=workspace-live"]);
    server.run_tmux(["new-session", "-d", "-s", "workspace-live"]);
    workspace
        .confirm_session_kill()
        .expect("begin guarded kill");
    wait_until(|| {
        workspace.drain_events().0.into_iter().any(|event| {
            matches!(event, WorkspaceEvent::Error(message) if message.contains("replaced after confirmation"))
        })
    });
    assert!(
        server.has_session("workspace-live"),
        "same-named replacement must survive"
    );

    wait_until_with_diagnostic(
        || {
            workspace.snapshot().hosts().first().is_some_and(|host| {
                host.sessions()
                    .iter()
                    .any(|session| session.name() == "workspace-live")
            })
        },
        || workspace_diagnostic(&workspace),
    );
    workspace
        .request_session_kill(&selection)
        .expect("query replacement identity");
    wait_until(|| workspace.session_kill_confirmation().is_some());
    workspace
        .confirm_session_kill()
        .expect("kill confirmed replacement");
    wait_until(|| !server.has_session("workspace-live"));
}

#[test]
#[ignore = "requires WSL2 and tmux; creates only an isolated TMUX_TMPDIR server"]
fn detach_restores_the_inventory_revalidated_during_attachment() {
    let _serial = WSL_LIVE
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let server = IsolatedServer::start("attach-inventory");
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    let workspace = Workspace::start_wsl(config, TerminalAppearance::default());

    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if sessions.len() == 1 && sessions[0].name() == "workspace-live"
            )
        },
        || workspace_diagnostic(&workspace),
    );
    server.run_tmux(["new-session", "-d", "-s", "appeared-before-attach"]);

    workspace
        .attach(&session_selection(&workspace, "workspace-live"))
        .expect("attach session after inventory changed");
    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Terminal { session, .. } if session == "workspace-live"
        )
    });
    workspace.detach();

    wait_until(|| {
        matches!(
            workspace.snapshot().content(),
            WorkspaceContent::Ready { sessions, .. }
                if sessions.iter().any(|session| session.name() == "appeared-before-attach")
        )
    });
}

fn terminal_contains(workspace: &Workspace, expected: &str) -> bool {
    let snapshot = workspace.snapshot();
    let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
        return false;
    };
    surface
        .load()
        .cells()
        .map(surface::Cell::text)
        .collect::<String>()
        .contains(expected)
}

#[track_caller]
fn wait_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "condition did not become true");
        thread::sleep(Duration::from_millis(25));
    }
}

#[track_caller]
fn wait_until_with_diagnostic(
    mut condition: impl FnMut() -> bool,
    diagnostic: impl Fn() -> String,
) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(
            Instant::now() < deadline,
            "condition did not become true: {}",
            diagnostic()
        );
        thread::sleep(Duration::from_millis(25));
    }
}

fn workspace_diagnostic(workspace: &Workspace) -> String {
    let snapshot = workspace.snapshot();
    let state = match snapshot.content() {
        WorkspaceContent::Shell => "shell".to_owned(),
        WorkspaceContent::Loading => "loading".to_owned(),
        WorkspaceContent::Ready { endpoint, sessions } => {
            format!("ready in {endpoint} with {} sessions", sessions.len())
        }
        WorkspaceContent::Attaching {
            endpoint, session, ..
        } => {
            format!("attaching {session} in {endpoint}")
        }
        WorkspaceContent::Terminal {
            endpoint, session, ..
        } => format!("attached to {session} in {endpoint}"),
        WorkspaceContent::Error { message } => format!("error: {message}"),
    };
    snapshot
        .notice()
        .map_or(state.clone(), |notice| format!("{state}; notice: {notice}"))
}

fn session_selection(workspace: &Workspace, session: &str) -> SessionSelection {
    let snapshot = workspace.snapshot();
    let host = &snapshot.hosts()[0];
    SessionSelection::new(host.id(), host.endpoint(), session)
}

fn active_presentation_id(workspace: &Workspace) -> u64 {
    match workspace.snapshot().content() {
        WorkspaceContent::Terminal {
            presentation_id, ..
        } => *presentation_id,
        _ => panic!("terminal presentation should be active"),
    }
}

fn start_workspace(server: &IsolatedServer) -> Workspace {
    let config = WslConfig::configured(None, "/usr/bin/tmux", Some(server.tmpdir.clone()))
        .expect("valid isolated config");
    Workspace::start_wsl(config, TerminalAppearance::default())
}

fn wait_for_sessions(workspace: &Workspace, expected: &[&str]) {
    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Ready { sessions, .. }
                    if expected.iter().all(|expected| {
                        sessions.iter().any(|session| session.name() == *expected)
                    })
            )
        },
        || workspace_diagnostic(workspace),
    );
}

fn wait_for_terminal(workspace: &Workspace, expected: &str) {
    wait_until_with_diagnostic(
        || {
            matches!(
                workspace.snapshot().content(),
                WorkspaceContent::Terminal { session, .. } if session == expected
            )
        },
        || workspace_diagnostic(workspace),
    );
}

fn assert_session_attached(server: &IsolatedServer, name: &str, expected: u32) {
    let output = server.run_tmux([
        "list-sessions",
        "-F",
        "#{session_name}\t#{session_attached}",
    ]);
    let sessions = String::from_utf8(output.stdout).expect("UTF-8 attached-client count");
    assert!(
        sessions
            .lines()
            .any(|line| line == format!("{name}\t{expected}")),
        "expected {name} to have {expected} attached client(s): {sessions:?}"
    );
}
