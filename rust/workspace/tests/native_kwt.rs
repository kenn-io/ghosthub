#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use config::TerminalAppearance;
use host::{
    CancellationToken, KwtBundle, LocalConfig, LocalExecutable, LocalHost, StdCommandRunner,
};
use workspace::{
    HostConnectionState, KeyInput, LocalHostSpec, Modifiers, NamedKey, ProjectItem,
    SessionSelection, Workspace, WorkspaceContent, WorkspaceEvent, WorktreeItem,
};

struct Fixture {
    workspace: Workspace,
    root: PathBuf,
    helper: PathBuf,
}

impl Fixture {
    fn new(root: PathBuf, helper: PathBuf) -> Self {
        let bytes = fs::read(&helper).unwrap();
        let digest = output(Command::new("/usr/bin/sha256sum").arg(&helper));
        let digest = String::from_utf8(digest.stdout).unwrap();
        let revision = include_str!("../../../KWT_REVISION").trim();
        let bundle = KwtBundle::new(revision, &digest[..64], Arc::<[u8]>::from(bytes)).unwrap();
        let config = LocalConfig::native(
            root.join("bin/tmux").to_str().unwrap(),
            Some(root.join("tmux").display().to_string()),
        )
        .unwrap()
        .with_kwt_bundle(bundle)
        .with_kwt_helper_root(root.join("helpers").display().to_string())
        .unwrap()
        .with_kwt_home_for_tests(root.join("kwt").display().to_string());
        // Exercise the host's input boundary before any helper mutation.
        let host =
            LocalHost::with_executable(config.clone(), StdCommandRunner, LocalExecutable::Native);
        let snapshot = host
            .discover_kwt_current(&CancellationToken::new())
            .unwrap();
        for path in [r"C:\repo", r"\\wsl.localhost\Linux\repo", "relative/repo"] {
            assert!(
                host.register_kwt_project(
                    snapshot.endpoint(),
                    snapshot.runtime(),
                    path,
                    &CancellationToken::new()
                )
                .is_err()
            );
        }
        let installed = root.join(format!("helpers/kwt/{revision}/{}/kwt", &digest[..64]));
        assert_eq!(fs::read(installed).unwrap(), fs::read(&helper).unwrap());
        let workspace = Workspace::application(
            TerminalAppearance::default(),
            Some(LocalHostSpec::native(config)),
        );
        let fixture = Self {
            workspace,
            root,
            helper,
        };
        fixture.tmux(&["new-session", "-d", "-s", "keep", "/bin/sh"]);
        fixture.tmux(&["set-option", "-g", "default-shell", "/bin/sh"]);
        fixture.tmux(&["set-option", "-g", "default-command", "/bin/sh"]);
        for args in [
            vec!["new-session", "-d", "-s", "keep", "/bin/sh"],
            vec!["set-option", "-g", "default-shell", "/bin/sh"],
            vec!["set-option", "-g", "default-command", "/bin/sh"],
        ] {
            output(
                Command::new("/usr/bin/tmux")
                    .env_remove("TMUX_TMPDIR")
                    .args(["-L", "kwt", "-f", "/dev/null"])
                    .args(args),
            );
        }
        fixture.kwt(&[
            "config",
            "set",
            "worktree.basedir",
            fixture.root.join("worktrees").to_str().unwrap(),
        ]);
        fixture.workspace.start_inventory_cadence().unwrap();
        fixture.workspace.connect_host("local").unwrap();
        fixture.wait(|| {
            let snapshot = fixture.workspace.snapshot();
            let local = &snapshot.hosts()[0];
            (local.connection() == HostConnectionState::Ready && local.can_add_kwt_project())
                .then_some(())
        });
        fixture
    }

    fn kwt(&self, args: &[&str]) -> Output {
        output(
            Command::new(&self.helper)
                .args(args)
                .current_dir(&self.root),
        )
    }

    fn tmux(&self, args: &[&str]) -> Output {
        output(
            Command::new("/usr/bin/tmux")
                .env("TMUX_TMPDIR", self.root.join("tmux"))
                .args(["-f", "/dev/null"])
                .args(args),
        )
    }

    fn project(&self) -> ProjectItem {
        self.workspace.snapshot().hosts()[0].projects()[0].clone()
    }

    fn endpoint(&self) -> String {
        self.workspace.snapshot().hosts()[0].endpoint().to_owned()
    }

    #[track_caller]
    fn wait<T>(&self, mut condition: impl FnMut() -> Option<T>) -> T {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if let Some(value) = condition() {
                return value;
            }
            assert!(
                Instant::now() < deadline,
                "native KWT timed out: notice={:?}, hosts={:?}",
                self.workspace.snapshot().notice(),
                self.workspace.snapshot().hosts()
            );
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn event<T>(&self, mut select: impl FnMut(WorkspaceEvent) -> Option<T>) -> T {
        self.wait(|| {
            self.workspace
                .drain_events()
                .0
                .into_iter()
                .find_map(|event| {
                    match &event {
                        WorkspaceEvent::Error(message)
                        | WorkspaceEvent::KwtWorktreeOperationFailed { message, .. }
                        | WorkspaceEvent::KwtProjectMutationFailed { message, .. } => {
                            panic!("{message}")
                        }
                        _ => {}
                    }
                    select(event)
                })
        })
    }

    fn mutate<T>(&self, mut submit: impl FnMut() -> Result<T, workspace::WorkspaceError>) -> T {
        // Success events can arrive before the worker releases its mutation lane.
        self.wait(|| match submit() {
            Ok(value) => Some(value),
            Err(error)
                if matches!(
                    error.to_string().as_str(),
                    "another KWT operation is already running"
                        | "another KWT project operation is already running"
                ) =>
            {
                None
            }
            Err(error) => panic!("{error}"),
        })
    }

    fn open(
        &self,
        project: &ProjectItem,
        worktree: &WorktreeItem,
    ) -> Result<(), workspace::WorkspaceError> {
        self.workspace.open_kwt_worktree(
            "local",
            &self.endpoint(),
            project.repository(),
            project.path(),
            project.registration_fingerprint(),
            worktree.path(),
            worktree.generation(),
            worktree.session_name(),
            worktree.tmux_socket_name(),
            worktree.tmux_attach_mode(),
        )
    }

    #[track_caller]
    fn probe(&self, worktree: &WorktreeItem) {
        self.probe_session(worktree.session_name());
    }

    #[track_caller]
    fn probe_session(&self, name: &str) {
        self.wait(|| {
            for event in self.workspace.drain_events().0 {
                if let WorkspaceEvent::Error(message) = event { panic!("{message}"); }
            }
            let snapshot = self.workspace.snapshot();
            matches!(snapshot.content(), WorkspaceContent::Terminal { session, .. } if session == name).then_some(())
        });
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let expected = format!("kwt-native-{nonce}");
        self.workspace
            .send_key(KeyInput::text(
                format!("printf 'kwt-native-%s\\n' {nonce}"),
                Modifiers::default(),
            ))
            .unwrap();
        self.workspace
            .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
            .unwrap();
        self.wait(|| {
            let snapshot = self.workspace.snapshot();
            let WorkspaceContent::Terminal { surface, .. } = snapshot.content() else {
                return None;
            };
            surface
                .load()
                .cells()
                .map(surface::Cell::text)
                .collect::<String>()
                .contains(&expected)
                .then_some(())
        });
    }

    fn create(&self, branch: &str, new_branch: bool) -> WorktreeItem {
        let project = self.project();
        self.mutate(|| {
            self.workspace.create_kwt_worktree(
                "local",
                &self.endpoint(),
                project.repository(),
                project.path(),
                project.registration_fingerprint(),
                branch,
                None,
                new_branch,
            )
        });
        self.event(|event| {
            matches!(event, WorkspaceEvent::KwtWorktreeCreated { .. }).then_some(())
        });
        self.wait(|| {
            self.project()
                .worktrees()
                .iter()
                .find(|worktree| worktree.branch() == branch)
                .cloned()
        })
    }

    fn review_removal(&self, worktree: &WorktreeItem) -> (u64, bool) {
        let project = self.project();
        self.workspace
            .request_kwt_worktree_removal(
                "local",
                &self.endpoint(),
                project.repository(),
                project.path(),
                project.registration_fingerprint(),
                worktree.path(),
                worktree.generation().unwrap(),
                worktree.session_name(),
                worktree.tmux_socket_name(),
                worktree.tmux_attach_mode(),
            )
            .unwrap();
        self.event(|event| match event {
            WorkspaceEvent::KwtWorktreeRemovalReady {
                authority,
                force_required,
                ..
            } => Some((authority, force_required)),
            _ => None,
        })
    }

    fn confirm_removal(
        &self,
        worktree: &WorktreeItem,
        authority: u64,
        force: bool,
    ) -> Result<(), workspace::WorkspaceError> {
        let project = self.project();
        self.workspace.remove_kwt_worktree(
            "local",
            &self.endpoint(),
            project.repository(),
            project.path(),
            project.registration_fingerprint(),
            worktree.path(),
            worktree.generation().unwrap(),
            worktree.session_name(),
            authority,
            force,
        )
    }

    fn remove(&self, worktree: &WorktreeItem) {
        let (authority, force_required) = self.review_removal(worktree);
        assert!(!force_required);
        self.mutate(|| self.confirm_removal(worktree, authority, false));
        self.event(|event| {
            matches!(event, WorkspaceEvent::KwtWorktreeRemoved { .. }).then_some(())
        });
        assert!(!Path::new(worktree.path()).exists());
        assert!(
            !Command::new("/usr/bin/tmux")
                .env_remove("TMUX_TMPDIR")
                .args(["-L", worktree.tmux_socket_name().unwrap()])
                .args([
                    "has-session",
                    "-t",
                    &format!("={}", worktree.session_name())
                ])
                .output()
                .unwrap()
                .status
                .success()
        );
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.workspace.close();
        let _ = Command::new(&self.helper)
            .args(["daemon", "stop"])
            .current_dir(&self.root)
            .output();
        let _ = Command::new("/usr/bin/tmux").arg("kill-server").output();
        let _ = Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args(["-L", "kwt", "kill-server"])
            .output();
    }
}

fn output(command: &mut Command) -> Output {
    let output = command
        .output()
        .unwrap_or_else(|error| panic!("{command:?}: {error}"));
    assert!(
        output.status.success(),
        "{command:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn isolated_fixture(test_name: &str, network: bool) -> Option<Fixture> {
    let helper =
        PathBuf::from(std::env::var_os("GHOSTHUB_KWT_BUNDLE_TEST").expect("staged Linux helper"));
    // Re-exec before starting threads so all subprocesses (including terminal
    // clients and KWT's daemon) inherit fixture-only Git, shell and service state.
    let Some(root) = std::env::var_os("GHOSTHUB_KWT_FIXTURE") else {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("gh-kwt-{}-{nonce:x}", std::process::id()));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        for dir in ["home", "kwt", "tmux", "repo with spaces", "config"] {
            fs::create_dir(root.join(dir)).unwrap();
        }
        fs::write(root.join("gitconfig"), "").unwrap();
        // The private /tmp can hide either original artifact, including the checkout.
        let bin = root.join("bin");
        fs::create_dir(&bin).unwrap();
        let executable = bin.join("native_kwt");
        let staged_helper = bin.join("kwt");
        fs::copy(std::env::current_exe().unwrap(), &executable).unwrap();
        fs::copy(&helper, &staged_helper).unwrap();
        let tmux = bin.join("tmux");
        fs::write(&tmux, r#"#!/bin/sh
if test -e "$HOME/delay-protected-session"; then
    case " $* " in
        *" new-session "*)
            socket=$(cat "$HOME/protected-socket")
            env -u TMUX_TMPDIR /usr/bin/tmux -L "$socket" -f /dev/null start-server \; set-option -s exit-empty off || exit
            touch "$HOME/creating-protected-session"
            while ! test -e "$HOME/probed-protected-session"; do sleep 0.02; done
            rm -f "$HOME/delay-protected-session"
            ;;
        *" list-clients "*)
            if test -e "$HOME/creating-protected-session"; then
                /usr/bin/tmux "$@"
                result=$?
                touch "$HOME/probed-protected-session"
                exit "$result"
            fi
            ;;
    esac
fi
exec /usr/bin/tmux "$@"
"#).unwrap();
        fs::set_permissions(&tmux, fs::Permissions::from_mode(0o700)).unwrap();
        let mut child = Command::new("bwrap");
        if !network {
            child.arg("--unshare-net");
        }
        child
            .args([
                "--unshare-user",
                "--unshare-pid",
                "--die-with-parent",
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--bind",
            ])
            .arg(&root)
            .arg(&root)
            .args(["--proc", "/proc", "--dev", "/dev"])
            .arg(executable)
            .current_dir(&root);
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("GIT_") {
                child.env_remove(key);
            }
        }
        let result = child
            .args(["--exact", test_name, "--ignored", "--nocapture"])
            .env("GHOSTHUB_KWT_FIXTURE", &root)
            .env("GHOSTHUB_KWT_BUNDLE_TEST", staged_helper)
            .env("PATH", format!("{}:/usr/bin:/bin", bin.display()))
            .env("HOME", root.join("home"))
            .env("XDG_CONFIG_HOME", root.join("config"))
            .env("KWT_HOME", root.join("kwt"))
            .env("TMUX_TMPDIR", root.join("tmux"))
            .env_remove("TMUX")
            .env_remove("TMUX_PANE")
            .env_remove("ENV")
            .env_remove("BASH_ENV")
            .env("SHELL", "/bin/sh")
            .env("GIT_CONFIG_GLOBAL", root.join("gitconfig"))
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .status()
            .unwrap();
        fs::remove_dir_all(root).unwrap();
        assert!(result.success());
        return None;
    };
    Some(Fixture::new(PathBuf::from(root), helper))
}

#[test]
#[ignore = "requires a staged pinned Linux KWT helper; run make rust-test-kwt-live"]
#[allow(
    clippy::too_many_lines,
    reason = "one real lifecycle shares an isolated repository and host"
)]
fn projects_and_worktrees_use_native_linux() {
    let Some(fixture) = isolated_fixture("projects_and_worktrees_use_native_linux", false) else {
        return;
    };
    let repo = fixture.root.join("repo with spaces");
    for args in [
        vec!["init", "-b", "main"],
        vec!["config", "user.name", "Demo"],
        vec!["config", "user.email", "demo@example.invalid"],
        vec!["commit", "--allow-empty", "-m", "Initial"],
        vec!["branch", "existing"],
    ] {
        output(Command::new("/usr/bin/git").arg("-C").arg(&repo).args(args));
    }
    fixture.mutate(|| {
        fixture
            .workspace
            .add_kwt_project("local", &fixture.endpoint(), repo.to_str().unwrap())
    });
    fixture.event(|event| {
        matches!(event, WorkspaceEvent::KwtProjectMutationFinished { .. }).then_some(())
    });
    fixture.wait(|| {
        (!fixture.workspace.snapshot().hosts()[0]
            .projects()
            .is_empty())
        .then_some(())
    });
    assert_eq!(fixture.project().path(), repo.to_str().unwrap());
    let created = fixture.create("feature", true);
    assert!(Path::new(created.path()).is_dir());
    fixture.open(&fixture.project(), &created).unwrap();
    fixture.probe(&created);
    fixture.workspace.detach();
    assert!(
        Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args(["-L", "kwt"])
            .args(["has-session", "-t", &format!("={}", created.session_name())])
            .status()
            .unwrap()
            .success()
    );
    let imported = fixture.create("existing", false);
    fixture.open(&fixture.project(), &imported).unwrap();
    fixture.probe(&imported);
    fixture.remove(&created);
    let replacement = fixture.create("feature", false);
    assert_eq!(replacement.path(), created.path());
    assert_ne!(replacement.generation(), created.generation());
    assert!(
        fixture.open(&fixture.project(), &created).is_err(),
        "old generation must not attach to its replacement"
    );
    fixture.open(&fixture.project(), &replacement).unwrap();
    fixture.probe(&replacement);
    fixture.remove(&replacement);
    let project = fixture.project();
    fixture.mutate(|| {
        fixture.workspace.remove_kwt_project(
            "local",
            &fixture.endpoint(),
            project.repository(),
            project.path(),
            project.registration_fingerprint(),
        )
    });
    fixture.event(|event| {
        matches!(event, WorkspaceEvent::KwtProjectMutationFinished { .. }).then_some(())
    });
    fixture.wait(|| {
        fixture.workspace.snapshot().hosts()[0]
            .projects()
            .is_empty()
            .then_some(())
    });
    assert!(repo.join(".git").is_dir());
    assert!(Path::new(imported.path()).is_dir());
    assert!(
        Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args(["-L", "kwt"])
            .args([
                "has-session",
                "-t",
                &format!("={}", imported.session_name())
            ])
            .status()
            .unwrap()
            .success()
    );
}

#[test]
#[ignore = "requires a staged pinned Linux KWT helper; run make rust-test-kwt-live"]
#[allow(clippy::too_many_lines)] // One real lifecycle checks both explicit discard and later edits.
fn local_force_removal_requires_fresh_explicit_approval() {
    let Some(fixture) = isolated_fixture(
        "local_force_removal_requires_fresh_explicit_approval",
        false,
    ) else {
        return;
    };
    let repo = fixture.root.join("repo with spaces");
    fs::write(repo.join("tracked.txt"), "committed\n").unwrap();
    for args in [
        vec!["init", "-b", "main"],
        vec!["config", "user.name", "Demo"],
        vec!["config", "user.email", "demo@example.invalid"],
        vec!["add", "tracked.txt"],
        vec!["commit", "-m", "Initial"],
    ] {
        output(Command::new("/usr/bin/git").arg("-C").arg(&repo).args(args));
    }
    fixture.mutate(|| {
        fixture
            .workspace
            .add_kwt_project("local", &fixture.endpoint(), repo.to_str().unwrap())
    });
    fixture.event(|event| {
        matches!(event, WorkspaceEvent::KwtProjectMutationFinished { .. }).then_some(())
    });
    fixture.wait(|| {
        (!fixture.workspace.snapshot().hosts()[0]
            .projects()
            .is_empty())
        .then_some(())
    });
    for branch in ["staged", "unstaged", "untracked"] {
        let worktree = fixture.create(branch, true);
        fixture.open(&fixture.project(), &worktree).unwrap();
        fixture.probe(&worktree);
        let path = Path::new(worktree.path());
        let file = path.join(if branch == "untracked" {
            "draft.txt"
        } else {
            "tracked.txt"
        });
        fs::write(&file, "work to discard\n").unwrap();
        if branch == "staged" {
            output(
                Command::new("/usr/bin/git")
                    .arg("-C")
                    .arg(path)
                    .args(["add", "tracked.txt"]),
            );
        }
        let (authority, force) = fixture.review_removal(&worktree);
        assert!(force, "dirty work needs an explicit force confirmation");
        assert!(
            fixture
                .confirm_removal(&worktree, authority, false)
                .is_err()
        );
        let (authority, force) = fixture.review_removal(&worktree);
        assert!(force);
        fixture.workspace.cancel_kwt_worktree_removal();
        assert!(fixture.confirm_removal(&worktree, authority, true).is_err());
        assert_eq!(fs::read_to_string(&file).unwrap(), "work to discard\n");
        output(
            Command::new("/usr/bin/tmux")
                .env_remove("TMUX_TMPDIR")
                .args([
                    "-L",
                    "kwt",
                    "has-session",
                    "-t",
                    &format!("={}", worktree.session_name()),
                ]),
        );
        let (authority, force) = fixture.review_removal(&worktree);
        assert!(force);
        fixture.mutate(|| fixture.confirm_removal(&worktree, authority, true));
        fixture.event(|event| {
            matches!(event, WorkspaceEvent::KwtWorktreeRemoved { .. }).then_some(())
        });
        assert!(!path.exists());
        output(Command::new("/usr/bin/git").arg("-C").arg(&repo).args([
            "show-ref",
            "--verify",
            &format!("refs/heads/{branch}"),
        ]));
        assert!(
            !Command::new("/usr/bin/tmux")
                .env_remove("TMUX_TMPDIR")
                .args([
                    "-L",
                    "kwt",
                    "has-session",
                    "-t",
                    &format!("={}", worktree.session_name())
                ])
                .status()
                .unwrap()
                .success()
        );
    }
    let worktree = fixture.create("later-edits", true);
    fixture.open(&fixture.project(), &worktree).unwrap();
    fixture.probe(&worktree);
    let (authority, force) = fixture.review_removal(&worktree);
    assert!(!force);
    assert!(fixture.confirm_removal(&worktree, authority, true).is_err());
    let (authority, force) = fixture.review_removal(&worktree);
    assert!(!force);
    let file = Path::new(worktree.path()).join("draft.txt");
    fs::write(&file, "keep later edits\n").unwrap();
    fixture.mutate(|| fixture.confirm_removal(&worktree, authority, false));
    let message = fixture.wait(|| {
        fixture
            .workspace
            .drain_events()
            .0
            .into_iter()
            .find_map(|event| match event {
                WorkspaceEvent::KwtWorktreeOperationFailed {
                    operation_id,
                    message,
                    ..
                } if operation_id == authority => Some(message),
                WorkspaceEvent::Error(message) => panic!("{message}"),
                _ => None,
            })
    });
    assert!(message.contains("Review it again"), "{message}");
    assert_eq!(fs::read_to_string(file).unwrap(), "keep later edits\n");
    fixture.probe(&worktree);
    let (authority, force) = fixture.review_removal(&worktree);
    assert!(force);
    fixture.mutate(|| fixture.confirm_removal(&worktree, authority, true));
    fixture.event(|event| matches!(event, WorkspaceEvent::KwtWorktreeRemoved { .. }).then_some(()));
    assert!(!Path::new(worktree.path()).exists());
}

#[test]
#[ignore = "requires a pinned helper, GitHub access and KWT_GITHUB_TOKEN; run make rust-test-kwt-pr-live"]
fn pull_request_import_attaches_to_the_protected_native_socket() {
    assert!(std::env::var("KWT_GITHUB_TOKEN").is_ok_and(|token| !token.is_empty()));
    let Some(fixture) = isolated_fixture(
        "pull_request_import_attaches_to_the_protected_native_socket",
        true,
    ) else {
        return;
    };
    let repo = fixture.root.join("hello-world");
    output(
        Command::new("/usr/bin/git")
            .args([
                "clone",
                "--quiet",
                "https://github.com/octocat/Hello-World.git",
            ])
            .arg(&repo),
    );
    fixture.mutate(|| {
        fixture
            .workspace
            .add_kwt_project("local", &fixture.endpoint(), repo.to_str().unwrap())
    });
    fixture.event(|event| {
        matches!(event, WorkspaceEvent::KwtProjectMutationFinished { .. }).then_some(())
    });
    let project = fixture.project();
    let import = || {
        fixture.mutate(|| {
            fixture.workspace.import_kwt_pull_request(
                "local",
                &fixture.endpoint(),
                project.repository(),
                project.path(),
                project.registration_fingerprint(),
                "https://github.com/octocat/Hello-World/pull/1",
            )
        });
        fixture.event(|event| match event {
            WorkspaceEvent::KwtWorktreeCreated { target, .. } => Some(target),
            _ => None,
        })
    };
    let first = import();
    let second = import();
    assert_eq!(first.worktree_path(), second.worktree_path());
    assert_eq!(first.generation(), second.generation());
    assert_eq!(first.tmux_attach_mode(), host::KwtTmuxAttachMode::Protected);
    let worktree = fixture
        .project()
        .worktrees()
        .iter()
        .find(|worktree| worktree.path() == first.worktree_path())
        .unwrap()
        .clone();
    let socket = worktree.tmux_socket_name().unwrap();
    assert!(
        !Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args([
                "-L",
                socket,
                "has-session",
                "-t",
                &format!("={}", worktree.session_name())
            ])
            .output()
            .unwrap()
            .status
            .success()
    );
    // KWT has resolved the absent server before new-session starts it. Hold
    // creation there until the readiness probe observes the empty server.
    fs::write(fixture.root.join("home/protected-socket"), socket).unwrap();
    fs::write(fixture.root.join("home/delay-protected-session"), "").unwrap();
    fixture.open(&project, &worktree).unwrap();
    fixture.probe(&worktree);
    assert!(fixture.root.join("home/probed-protected-session").exists());
    fixture.workspace.detach();
    output(
        Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args([
                "-L",
                socket,
                "set-option",
                "-s",
                "exit-empty",
                "on",
                ";",
                "kill-session",
                "-t",
                &format!("={}", worktree.session_name()),
            ]),
    );
    fixture.open(&project, &worktree).unwrap();
    fixture.probe(&worktree);
    fixture.remove(&worktree);
}

#[test]
#[ignore = "requires a staged pinned Linux KWT helper; run make rust-test-kwt-live"]
fn rename_keeps_clients_attached_across_scenes_and_retained_navigation() {
    let Some(fixture) = isolated_fixture(
        "rename_keeps_clients_attached_across_scenes_and_retained_navigation",
        false,
    ) else {
        return;
    };
    fixture.tmux(&["new-session", "-d", "-s", "work", "/bin/sh"]);
    fixture.workspace.refresh().unwrap();
    let selection = SessionSelection::new("local", fixture.endpoint(), "work");
    fixture.wait(|| fixture.workspace.session_rename_request(&selection).ok());
    fixture.workspace.attach(&selection).unwrap();
    fixture.probe_session("work");
    let other = fixture.workspace.open_scene();
    other.select_host("local").unwrap();
    other.switch_session(&selection).unwrap();
    fixture.wait(|| matches!(other.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "work").then_some(()));
    other
        .switch_session(&SessionSelection::new("local", fixture.endpoint(), "keep"))
        .unwrap();
    fixture.wait(|| matches!(other.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "keep").then_some(()));
    fixture.wait(|| {
        (fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                "=keep:",
                "#{session_attached}",
            ])
            .stdout
            == b"1\n")
            .then_some(())
    });
    let clients = fixture
        .tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"])
        .stdout;
    let identity = fixture
        .tmux(&[
            "display-message",
            "-p",
            "-t",
            "=work:",
            "#{pid}:#{session_id}:#{session_created}",
        ])
        .stdout;
    let request = fixture
        .workspace
        .session_rename_request(&selection)
        .unwrap();
    fixture
        .workspace
        .rename_session(&request, "release 'one")
        .unwrap();
    fixture.event(|event| match event {
        WorkspaceEvent::SessionRenamed { result, .. } => {
            result.unwrap();
            Some(())
        }
        _ => None,
    });
    fixture.probe_session("release 'one");
    assert_eq!(
        fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                "=release 'one:",
                "#{pid}:#{session_id}:#{session_created}"
            ])
            .stdout,
        identity
    );
    assert_eq!(
        fixture
            .tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"])
            .stdout,
        clients
    );
    other
        .switch_session(&SessionSelection::new(
            "local",
            fixture.endpoint(),
            "release 'one",
        ))
        .unwrap();
    fixture.wait(|| matches!(other.snapshot().content(), WorkspaceContent::Terminal { session, .. } if session == "release 'one").then_some(()));
    assert_eq!(
        fixture
            .tmux(&["list-clients", "-F", "#{client_pid}:#{session_id}"])
            .stdout,
        clients
    );
    other.close();
}

#[test]
#[ignore = "requires a staged pinned Linux KWT helper; run make rust-test-kwt-live"]
fn rename_rejects_replacement_collision_and_kwt_owned_names() {
    let Some(fixture) = isolated_fixture(
        "rename_rejects_replacement_collision_and_kwt_owned_names",
        false,
    ) else {
        return;
    };
    fixture.tmux(&["new-session", "-d", "-s", "work", "/bin/sh"]);
    fixture.workspace.refresh().unwrap();
    let selection = SessionSelection::new("local", fixture.endpoint(), "work");
    let request = fixture.wait(|| fixture.workspace.session_rename_request(&selection).ok());
    for name in [
        "keep",
        "kwt-wt-owned",
        "kwt-workspace-owned",
        "invalid.name",
    ] {
        assert!(
            fixture.workspace.rename_session(&request, name).is_err(),
            "accepted {name}"
        );
    }
    fixture.tmux(&["rename-session", "-t", "=work:", "original"]);
    fixture.tmux(&["new-session", "-d", "-s", "work", "/bin/sh"]);
    let replacement = fixture
        .tmux(&[
            "display-message",
            "-p",
            "-t",
            "=work:",
            "#{pid}:#{session_id}:#{session_created}",
        ])
        .stdout;
    fixture.workspace.rename_session(&request, "wrong").unwrap();
    fixture.event(|event| match event {
        WorkspaceEvent::SessionRenamed { result, .. } => Some(result.unwrap_err()),
        _ => None,
    });
    assert_eq!(
        fixture
            .tmux(&[
                "display-message",
                "-p",
                "-t",
                "=work:",
                "#{pid}:#{session_id}:#{session_created}"
            ])
            .stdout,
        replacement
    );
    let output = Command::new("/usr/bin/tmux")
        .args(["has-session", "-t", "=wrong:"])
        .output()
        .unwrap();
    assert!(!output.status.success());
    fixture.tmux(&["has-session", "-t", "=original:"]);
}
