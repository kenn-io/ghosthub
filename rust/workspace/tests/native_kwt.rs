#![cfg(target_os = "linux")]

use std::fs;
use std::os::unix::fs::DirBuilderExt;
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
    HostConnectionState, KeyInput, LocalHostSpec, Modifiers, NamedKey, ProjectItem, Workspace,
    WorkspaceContent, WorkspaceEvent, WorktreeItem,
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
            "/usr/bin/tmux",
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
                "native KWT timed out: {:?}",
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

    fn probe(&self, worktree: &WorktreeItem) {
        self.wait(|| {
            for event in self.workspace.drain_events().0 {
                if let WorkspaceEvent::Error(message) = event { panic!("{message}"); }
            }
            let snapshot = self.workspace.snapshot();
            matches!(snapshot.content(), WorkspaceContent::Terminal { session, .. } if session == worktree.session_name()).then_some(())
        });
        self.workspace
            .send_key(KeyInput::text(
                "printf 'kwt-native-%s\\n' ready",
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
                .contains("kwt-native-ready")
                .then_some(())
        });
    }

    fn create(&self, branch: &str, new_branch: bool) -> WorktreeItem {
        let project = self.project();
        self.workspace
            .create_kwt_worktree(
                "local",
                &self.endpoint(),
                project.repository(),
                project.path(),
                project.registration_fingerprint(),
                branch,
                None,
                new_branch,
            )
            .unwrap();
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

    fn remove(&self, worktree: &WorktreeItem) {
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
        let authority = self.event(|event| match event {
            WorkspaceEvent::KwtWorktreeRemovalReady {
                authority,
                session_was_running,
                ..
            } => {
                assert!(session_was_running);
                Some(authority)
            }
            _ => None,
        });
        self.workspace
            .remove_kwt_worktree(
                "local",
                &self.endpoint(),
                project.repository(),
                project.path(),
                project.registration_fingerprint(),
                worktree.path(),
                worktree.generation().unwrap(),
                worktree.session_name(),
                authority,
            )
            .unwrap();
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
            .arg(std::env::current_exe().unwrap());
        for (key, _) in std::env::vars_os() {
            if key.to_string_lossy().starts_with("GIT_") {
                child.env_remove(key);
            }
        }
        let result = child
            .args(["--exact", test_name, "--ignored", "--nocapture"])
            .env("GHOSTHUB_KWT_FIXTURE", &root)
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
    fixture
        .workspace
        .add_kwt_project("local", &fixture.endpoint(), repo.to_str().unwrap())
        .unwrap();
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
    fixture
        .workspace
        .remove_kwt_project(
            "local",
            &fixture.endpoint(),
            project.repository(),
            project.path(),
            project.registration_fingerprint(),
        )
        .unwrap();
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
    fixture
        .workspace
        .add_kwt_project("local", &fixture.endpoint(), repo.to_str().unwrap())
        .unwrap();
    fixture.event(|event| {
        matches!(event, WorkspaceEvent::KwtProjectMutationFinished { .. }).then_some(())
    });
    let project = fixture.project();
    let import = || {
        fixture
            .workspace
            .import_kwt_pull_request(
                "local",
                &fixture.endpoint(),
                project.repository(),
                project.path(),
                project.registration_fingerprint(),
                "https://github.com/octocat/Hello-World/pull/1",
            )
            .unwrap();
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
    fixture.open(&project, &worktree).unwrap();
    fixture.probe(&worktree);
    fixture.workspace.detach();
    output(
        Command::new("/usr/bin/tmux")
            .env_remove("TMUX_TMPDIR")
            .args([
                "-L",
                socket,
                "kill-session",
                "-t",
                &format!("={}", worktree.session_name()),
            ]),
    );
    fixture.open(&project, &worktree).unwrap();
    fixture.probe(&worktree);
    fixture.remove(&worktree);
}
