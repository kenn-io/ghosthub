use super::*;
use std::io::Write as _;
use std::os::unix::fs::PermissionsExt;

struct Process {
    child: std::process::Child,
}

impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn rex(fixture: &Fixture, arguments: &[&str]) -> serde_json::Value {
    let output = Command::new(fixture.root.join("bin/rex"))
        .args(arguments)
        .output()
        .unwrap();
    assert!(output.status.success(), "Rex {arguments:?}: {output:?}");
    serde_json::from_slice(&output.stdout).unwrap()
}

fn server(fixture: &Fixture) -> Process {
    let log = std::fs::File::create(fixture.root.join("rex.log")).unwrap();
    let server = Command::new(fixture.root.join("bin/rex"))
        .args([
            "server",
            "run",
            "--listen",
            &format!("unix://{}", fixture.root.join("rex.sock").display()),
            "--state-dir",
            fixture.root.join("rex-state").to_str().unwrap(),
            "--restore=false",
        ])
        .stdout(log.try_clone().unwrap())
        .stderr(log)
        .spawn()
        .unwrap();
    let owned = Process { child: server };
    let deadline = Instant::now() + Duration::from_secs(10);
    while !fixture.root.join("rex.sock").exists() {
        assert!(
            Instant::now() < deadline,
            "{}",
            std::fs::read_to_string(fixture.root.join("rex.log")).unwrap()
        );
        thread::sleep(Duration::from_millis(20));
    }
    owned
}

fn ui_command() -> Command {
    let root =
        std::env::var_os("GHOSTHUB_SSH_FIXTURE").expect("desktop tests need the SSH fixture");
    let mut command = Command::new(Path::new(&root).join("bin/xdotool"));
    command.env("DISPLAY", ":93");
    command
}

fn ui(arguments: &[&str]) -> String {
    let output = ui_command().args(arguments).output().unwrap();
    assert!(output.status.success(), "xdotool {arguments:?}: {output:?}");
    String::from_utf8(output.stdout).unwrap()
}

fn ui_key(key: &str) {
    ui(&["key", "--clearmodifiers", key]);
    thread::sleep(Duration::from_millis(300));
}

fn ui_type(text: &str) {
    ui(&["type", "--clearmodifiers", "--delay", "2", "--", text]);
}

fn ui_probe(command: &str) {
    ui_type(command);
    ui_key("Return");
}

fn ui_palette(query: &str) {
    ui_key("Escape");
    ui_key("ctrl+shift+p");
    ui_type(query);
    ui_key("Return");
}

fn wait_ui(fixture: &Fixture, description: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(45);
    while !ready() {
        assert!(
            Instant::now() < deadline,
            "{description}: {}",
            ["app-ui.log", "xvfb-ui.log"]
                .map(|name| std::fs::read_to_string(fixture.root.join(name)).unwrap_or_default())
                .join("\n")
        );
        thread::sleep(Duration::from_millis(30));
    }
}

fn gui_view(fixture: &Fixture, window: &str) -> serde_json::Value {
    let output = Command::new(&fixture.kwt)
        .args(["rex", "control", window])
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    serde_json::from_slice(
        output
            .stdout
            .split(|b| *b == b'\n')
            .find(|line| !line.is_empty())
            .unwrap(),
    )
    .unwrap()
}

#[test]
#[ignore = "requires Rex, Xvfb, and the native app; run make rust-test-rex-live"]
#[allow(
    clippy::too_many_lines,
    reason = "Exercise keyboard focus through the real native window and Rex server."
)]
fn desktop_routes_keyboard_to_the_focused_rex_pane() {
    assert!(
        std::env::var_os("GHOSTHUB_REX_APP_TEST").is_some()
            || std::env::var_os("GHOSTHUB_SSH_FIXTURE").is_some(),
        "Run make rust-test-rex-live"
    );
    let Some(fixture) =
        Fixture::isolated("native_ssh::rex::desktop_routes_keyboard_to_the_focused_rex_pane")
    else {
        return;
    };
    let _server = server(&fixture);
    let created = rex(
        &fixture,
        &[
            "new",
            "Studio",
            "--window",
            "Work",
            "--json",
            "--shell=none",
            "--",
            "/bin/sh",
        ],
    );
    let window = created["initial_windows"][0]["window_id"].as_str().unwrap();
    let original = created["initial_windows"][0]["block_ids"][0]
        .as_str()
        .unwrap();
    fixture.connect();
    fixture.wait(|s| s.hosts().iter().any(|h| !h.rex_windows().is_empty()));
    std::fs::create_dir_all("/tmp/.X11-unix").unwrap();
    std::fs::set_permissions("/tmp/.X11-unix", std::fs::Permissions::from_mode(0o1777)).unwrap();
    let xvfb_log = std::fs::File::create(fixture.root.join("xvfb-ui.log")).unwrap();
    let _xvfb = Process {
        child: Command::new("Xvfb")
            .args([":93", "-screen", "0", "1100x720x24", "-nolisten", "tcp"])
            .stdout(xvfb_log.try_clone().unwrap())
            .stderr(xvfb_log)
            .spawn()
            .unwrap(),
    };
    wait_ui(&fixture, "Xvfb did not start", || {
        ui_command()
            .arg("getdisplaygeometry")
            .output()
            .is_ok_and(|o| o.status.success())
    });
    let icd = std::fs::read_to_string(fixture.root.join("rex-icd")).unwrap_or_else(|_| {
        std::fs::read_dir("/usr/share/vulkan/icd.d")
            .unwrap()
            .filter_map(Result::ok)
            .find(|e| e.file_name().to_string_lossy().starts_with("lvp_icd"))
            .expect("install mesa-vulkan-drivers")
            .path()
            .to_string_lossy()
            .into_owned()
    });
    let app_log = std::fs::File::create(fixture.root.join("app-ui.log")).unwrap();
    let _app = Process {
        child: Command::new(fixture.root.join("bin/ghosthub-native"))
            .env("DISPLAY", ":93")
            .env("VK_ICD_FILENAMES", icd.trim())
            .env("LP_NUM_THREADS", "2")
            .stdout(app_log.try_clone().unwrap())
            .stderr(app_log)
            .spawn()
            .unwrap(),
    };
    let mut app_window = String::new();
    wait_ui(&fixture, "native window did not open", || {
        let output = ui_command()
            .args(["search", "--onlyvisible", "--name", "Ghosthub"])
            .output()
            .unwrap();
        app_window = String::from_utf8_lossy(&output.stdout)
            .lines()
            .next()
            .unwrap_or_default()
            .to_owned();
        output.status.success()
    });
    ui(&["windowfocus", "--sync", &app_window]);
    ui_palette("Connect Studio");
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        ui_palette("Work rex");
        if ui(&["getwindowname", &app_window]).contains("Work") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Rex window was not offered by the palette"
        );
    }
    wait_ui(&fixture, "first pane did not accept input", || {
        ui_probe("rex_pane=one; printf '%s' \"$rex_pane\" > /tmp/rex-gui-ready");
        std::fs::read_to_string("/tmp/rex-gui-ready").is_ok_and(|s| s == "one")
    });
    ui_key("ctrl+shift+d");
    wait_ui(&fixture, "Split Right did not reach Rex", || {
        gui_view(&fixture, window)["view"]["windows"][0]["layers"][0]["layout"]["split"].is_object()
    });
    wait_ui(&fixture, "second pane did not accept input", || {
        ui_probe("rex_pane=two; printf '%s' \"$rex_pane\" > /tmp/rex-gui-second");
        std::fs::read_to_string("/tmp/rex-gui-second").is_ok_and(|s| s == "two")
    });
    ui_key("ctrl+alt+Left");
    wait_ui(&fixture, "left pane did not take focus", || {
        gui_view(&fixture, window)["view"]["windows"][0]["focused_block_id"] == original
    });
    ui_probe("printf '%s' \"$rex_pane\" > /tmp/rex-gui-left");
    wait_ui(&fixture, "typing after pane focus was lost", || {
        std::fs::read_to_string("/tmp/rex-gui-left").is_ok_and(|s| s == "one")
    });
    ui_key("ctrl+bracketright");
    ui_probe("printf '%s' \"$rex_pane\" > /tmp/rex-gui-next");
    wait_ui(&fixture, "next pane did not receive typing", || {
        std::fs::read_to_string("/tmp/rex-gui-next").is_ok_and(|s| s == "two")
    });
    ui_key("ctrl+shift+Return");
    wait_ui(&fixture, "Zoom did not reach Rex", || {
        gui_view(&fixture, window)["view"]["windows"][0]["zoomed_block_id"].is_string()
    });
    ui_key("ctrl+shift+Return");
    wait_ui(&fixture, "Zoom did not restore the layout", || {
        gui_view(&fixture, window)["view"]["windows"][0]["zoomed_block_id"].is_null()
    });
    ui_palette("review tmux");
    wait_ui(&fixture, "tmux client did not attach", || {
        Command::new("tmux")
            .env("TMUX_TMPDIR", fixture.root.join("tmux"))
            .args(["list-clients", "-F", "#{client_session}"])
            .output()
            .is_ok_and(|o| o.status.success() && o.stdout == b"review\n")
    });
    ui_probe("tmux display-message -p -t \"$TMUX_PANE\" '#S' > /tmp/rex-gui-tmux");
    wait_ui(&fixture, "ordinary terminal lost keyboard focus", || {
        std::fs::read_to_string("/tmp/rex-gui-tmux").is_ok_and(|s| s == "review\n")
    });
    ui_palette("Work rex");
    wait_ui(
        &fixture,
        "Rex programs did not survive switching away",
        || {
            // Reopening starts new SSH clients. Probe until their terminal is ready.
            ui_probe("printf '%s' \"$rex_pane\" > /tmp/rex-gui-reopened");
            std::fs::read_to_string("/tmp/rex-gui-reopened").is_ok_and(|s| s == "two")
        },
    );
    ui_palette("Close Pane");
    ui_key("Return");
    assert!(
        gui_view(&fixture, window)["view"]["windows"][0]["layers"][0]["layout"]["split"]
            .is_object(),
        "Cancel ended a program"
    );
    ui_palette("Close Pane");
    ui_key("Tab");
    ui_key("Return");
    wait_ui(&fixture, "confirmed Close Pane did not reach Rex", || {
        gui_view(&fixture, window)["view"]["windows"][0]["layers"][0]["layout"]["block_id"]
            == original
    });
    fixture.workspace.close();
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "Keep the same real server and panes through the lifecycle workflow."
)]
#[ignore = "requires a Rex server executable; run make rust-test-rex-live"]
fn remote_windows_keep_backend_layout_and_programs_after_detach() {
    assert!(
        std::env::var_os("GHOSTHUB_REX_TEST").is_some()
            || std::env::var_os("GHOSTHUB_SSH_FIXTURE").is_some(),
        "Run make rust-test-rex-live with REX_BINARY_PATH"
    );
    let Some(fixture) = Fixture::isolated(
        "native_ssh::rex::remote_windows_keep_backend_layout_and_programs_after_detach",
    ) else {
        return;
    };
    let _server = server(&fixture);
    let created = rex(
        &fixture,
        &[
            "new",
            "Studio",
            "--window",
            "Work",
            "--json",
            "--shell=none",
            "--",
            "/bin/sh",
        ],
    );
    let window_id = created["initial_windows"][0]["window_id"].as_str().unwrap();
    let original_block = created["initial_windows"][0]["block_ids"][0]
        .as_str()
        .unwrap();
    let mut draft = fixture
        .workspace
        .configured_ssh_hosts()
        .into_iter()
        .find(|h| h.id() == fixture.host_id)
        .unwrap()
        .draft()
        .clone();
    draft.tmux_binary = "/missing-tmux".into();
    fixture
        .workspace
        .save_ssh_host(Some(&fixture.host_id), &draft)
        .unwrap();
    fixture.connect();
    assert!(
        !fixture
            .workspace
            .snapshot()
            .hosts()
            .iter()
            .find(|h| h.id() == fixture.host_id)
            .unwrap()
            .tmux_available()
    );
    fixture.wait(|snapshot| {
        snapshot
            .hosts()
            .iter()
            .any(|h| h.id() == fixture.host_id && h.rex_windows().iter().any(|w| w.id == window_id))
    });
    // Exercise a real login script whose last output abuts the control marker.
    writeln!(
        std::fs::OpenOptions::new()
            .append(true)
            .open(fixture.root.join("home/.profile"))
            .unwrap(),
        "printf '%s' 'Welcome to the build host'"
    )
    .unwrap();
    let selection = SessionSelection::rex(&fixture.host_id, &fixture.endpoint, window_id);
    fixture.workspace.select_host(&fixture.host_id).unwrap();
    fixture.workspace.switch_session(&selection).unwrap();
    fixture.wait(|snapshot| {
        snapshot.rex_window().is_some_and(|w| {
            assert!(w.error.is_none(), "Rex window failed: {:?}", w.error);
            w.panes.len() == 1 && fixture.terminal_text().contains("$ ")
        })
    });
    fixture
        .workspace
        .send_key(KeyInput::text(
            "rex_pane=original; printf '%s%s\\n' rex- ready > /tmp/rex-original",
            Modifiers::default(),
        ))
        .unwrap();
    fixture
        .workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .unwrap();
    fixture
        .wait(|_| std::fs::read_to_string("/tmp/rex-original").is_ok_and(|s| s == "rex-ready\n"));
    let original_presentation =
        fixture.workspace.snapshot().rex_window().unwrap().panes[0].presentation_id;
    fixture.workspace.split_rex_pane(false).unwrap();
    fixture.wait(|snapshot| {
        snapshot.rex_window().is_some_and(|w| {
            assert!(w.error.is_none(), "{:?}", w.error);
            w.panes.len() == 2
                && w.panes.iter().all(|p| !p.connecting && p.error.is_none())
                && w.panes
                    .iter()
                    .find(|p| p.id == original_block)
                    .is_some_and(|p| p.presentation_id == original_presentation)
        })
    });
    assert_eq!(
        fixture
            .workspace
            .snapshot()
            .hosts()
            .iter()
            .find(|h| h.id() == fixture.host_id)
            .unwrap()
            .rex_windows()[0]
            .detail,
        "Studio · 2 panes"
    );
    resize_with_full_input_queue(&fixture);
    fixture
        .workspace
        .send_key(KeyInput::text(
            "stty size > /tmp/rex-grid; rex_pane=new; printf '%s%s\\n' new- pane > /tmp/rex-new",
            Modifiers::default(),
        ))
        .unwrap();
    fixture
        .workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .unwrap();
    fixture.wait(|_| std::fs::read_to_string("/tmp/rex-new").is_ok_and(|s| s == "new-pane\n"));
    fixture.wait(|_| std::fs::read_to_string("/tmp/rex-grid").is_ok_and(|s| s == "28 49\n"));
    fixture
        .workspace
        .focus_rex_pane(original_presentation)
        .unwrap();
    fixture
        .workspace
        .send_key(KeyInput::text(
            "printf '%s%s\\n' focused- \"$rex_pane\" > /tmp/rex-focused",
            Modifiers::default(),
        ))
        .unwrap();
    fixture
        .workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .unwrap();
    fixture.wait(|_| {
        std::fs::read_to_string("/tmp/rex-focused").is_ok_and(|s| s == "focused-original\n")
    });
    fixture.workspace.zoom_rex_pane().unwrap();
    fixture.wait(|s| {
        s.rex_window()
            .is_some_and(|w| w.panes.iter().filter(|p| p.rect.width > 0.0).count() == 1)
    });
    fixture.workspace.zoom_rex_pane().unwrap();
    fixture.wait(|s| s.rex_window().is_some_and(|w| w.dividers.len() == 1));
    let divider = fixture.workspace.snapshot().rex_window().unwrap().dividers[0]
        .id
        .clone();
    fixture.workspace.resize_rex_split(&divider, 0.7).unwrap();
    fixture.wait(|s| {
        s.rex_window()
            .is_some_and(|w| (w.dividers[0].ratio - 0.7).abs() < 0.01)
    });
    fixture.workspace.split_rex_pane(true).unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.panes.len() == 3 && w.panes.iter().all(|p| !p.connecting && p.error.is_none())
        })
    });
    let closing = fixture
        .workspace
        .snapshot()
        .rex_window()
        .unwrap()
        .panes
        .iter()
        .find(|p| p.focused)
        .unwrap()
        .presentation_id;
    fixture.workspace.close_rex_pane(closing).unwrap();
    fixture.wait(|s| s.rex_window().is_some_and(|w| w.panes.len() == 2));
    assert!(fixture.workspace.close_rex_pane(closing).is_err());
    fixture.workspace.detach();
    assert!(fixture.workspace.snapshot().rex_window().is_none());
    let output = Command::new(&fixture.kwt)
        .args(["rex", "ls", "--json"])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let listing: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(listing["terminals"].as_array().unwrap().len(), 2);
    fixture.workspace.switch_session(&selection).unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.panes.len() == 2
                && w.error.is_none()
                && w.panes.iter().all(|p| !p.connecting && p.error.is_none())
        })
    });
    assert!(
        fixture
            .workspace
            .close_rex_pane(original_presentation)
            .is_err(),
        "a reopened pane accepted an old confirmation"
    );
    let pending_close = fixture
        .workspace
        .snapshot()
        .rex_window()
        .unwrap()
        .panes
        .iter()
        .find(|p| p.focused)
        .unwrap()
        .presentation_id;
    {
        let _pump = fixture.workspace.pause_event_pump();
        fixture.connect();
        let rejected = fixture.workspace.close_rex_pane(pending_close).unwrap_err();
        assert!(
            rejected.to_string().contains("SSH connection changed"),
            "{rejected}"
        );
    }
    fixture.workspace.switch_session(&selection).unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.panes.len() == 2
                && w.error.is_none()
                && w.panes.iter().all(|p| !p.connecting && p.error.is_none())
        })
    });
    let ending = fixture
        .workspace
        .snapshot()
        .rex_window()
        .unwrap()
        .panes
        .iter()
        .find(|p| p.focused)
        .unwrap()
        .presentation_id;
    fixture
        .workspace
        .send_key(KeyInput::text("exit", Modifiers::default()))
        .unwrap();
    fixture
        .workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.error.is_none()
                && w.panes
                    .iter()
                    .find(|p| p.presentation_id == ending)
                    .is_none_or(|p| p.error.is_some())
        })
    });
    if fixture
        .workspace
        .snapshot()
        .rex_window()
        .unwrap()
        .panes
        .iter()
        .any(|p| p.presentation_id == ending)
    {
        fixture.workspace.close_rex_pane(ending).unwrap();
    }
    fixture.wait(|s| {
        s.rex_window()
            .is_some_and(|w| w.error.is_none() && w.panes.len() == 1)
    });
    fixture.workspace.remove_ssh_host(&fixture.host_id).unwrap();
    assert!(
        fixture.workspace.snapshot().rex_window().is_none(),
        "host removal left its Rex window open"
    );
    assert!(matches!(
        fixture.workspace.snapshot().content(),
        WorkspaceContent::Shell
    ));
    let survivors = Command::new(&fixture.kwt)
        .args(["rex", "ls", "--json"])
        .output()
        .unwrap();
    let survivors: serde_json::Value = serde_json::from_slice(&survivors.stdout).unwrap();
    assert_eq!(
        survivors["terminals"].as_array().unwrap().len(),
        1,
        "removing the SSH host ended a Rex program"
    );
    fixture.workspace.close();
}

#[test]
#[ignore = "requires a Rex server executable; run make rust-test-rex-live"]
fn remote_rex_navigation_and_pane_reconnect_preserve_clients() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::rex::remote_rex_navigation_and_pane_reconnect_preserve_clients",
    ) else {
        return;
    };
    let _server = server(&fixture);
    let created = rex(
        &fixture,
        &[
            "new",
            "Studio",
            "--window",
            "Work",
            "--json",
            "--shell=none",
            "--",
            "/bin/sh",
        ],
    );
    let window = created["initial_windows"][0]["window_id"].as_str().unwrap();
    let block = created["initial_windows"][0]["block_ids"][0]
        .as_str()
        .unwrap();
    let local = fixture.local_session("local-one");
    let unopened = fixture.local_session("local-two");
    fixture.connect();
    fixture.wait(|s| {
        s.hosts()
            .iter()
            .any(|h| h.rex_windows().iter().any(|w| w.id == window))
    });
    fixture.workspace.select_host(&fixture.host_id).unwrap();
    fixture.attach("review", "before-rex");
    let WorkspaceContent::Terminal {
        presentation_id: review,
        ..
    } = *fixture.workspace.snapshot().content()
    else {
        panic!("review did not open");
    };
    let selection = SessionSelection::rex(&fixture.host_id, &fixture.endpoint, window);
    let open_rex = || {
        fixture.workspace.select_host(&fixture.host_id).unwrap();
        fixture.workspace.switch_session(&selection).unwrap();
        fixture.wait(|s| {
            s.rex_window()
                .is_some_and(|w| w.panes.len() == 1 && w.error.is_none())
                && fixture.terminal_text().contains("$ ")
        });
    };
    open_rex();
    fixture.attach("review", "after-rex");
    assert!(matches!(fixture.workspace.snapshot().content(),
        WorkspaceContent::Terminal { presentation_id, .. } if *presentation_id == review));
    open_rex();
    fixture.attach("notes 'one'", "other-after-rex");
    open_rex();
    fixture.workspace.select_host(local.host_id()).unwrap();
    fixture.workspace.switch_session(&local).unwrap();
    fixture.wait(|s| matches!(s.content(), WorkspaceContent::Terminal { session, .. } if session == "local-one"));

    leave_pending_rex(&fixture, &selection, &unopened);
    open_rex();
    reconnect_failed_pane(&fixture, block);
    fixture.workspace.close();
}

fn leave_pending_rex(fixture: &Fixture, rex: &SessionSelection, local: &SessionSelection) {
    // Keep the real terminfo probe in flight before the control channel is published.
    let probe = fixture.root.join("bin/infocmp");
    let started = fixture.root.join("rex-probe-started");
    let gate = fixture.root.join("hold-rex-probe");
    std::fs::write(&gate, "").unwrap();
    std::fs::write(&probe, format!(
        "#!/bin/sh\ntouch '{}'\nwhile [ -f '{}' ]; do sleep 0.02; done\nexec /usr/bin/infocmp \"$@\"\n",
        started.display(), gate.display(),
    )).unwrap();
    std::fs::set_permissions(&probe, std::fs::Permissions::from_mode(0o700)).unwrap();
    fixture.workspace.select_host(&fixture.host_id).unwrap();
    fixture.workspace.switch_session(rex).unwrap();
    fixture.wait(|s| {
        started.exists()
            && s.rex_window().is_none()
            && matches!(
                s.content(),
                WorkspaceContent::Attaching {
                    kind: workspace::SessionKind::Rex,
                    ..
                }
            )
    });
    fixture.workspace.select_host(local.host_id()).unwrap();
    let result = fixture.workspace.switch_session(local);
    std::fs::remove_file(gate).unwrap();
    result.unwrap();
    fixture.wait(|s| {
        s.rex_window().is_none()
            && matches!(s.content(),
        WorkspaceContent::Terminal { session, .. } if session == local.session())
    });
}

fn reconnect_failed_pane(fixture: &Fixture, block: &str) {
    fixture.workspace.split_rex_pane(false).unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.panes.len() == 2 && w.panes.iter().all(|p| !p.connecting && p.error.is_none())
        })
    });
    let before = fixture.workspace.snapshot();
    let panes = &before.rex_window().unwrap().panes;
    let other = panes
        .iter()
        .find(|p| p.id != block)
        .unwrap()
        .presentation_id;
    let first = panes
        .iter()
        .find(|p| p.id == block)
        .unwrap()
        .presentation_id;
    fixture.workspace.focus_rex_pane(first).unwrap();
    rex_probe(
        fixture,
        "rex_saved=kept; printf '%s' \"$rex_saved\" > /tmp/rex-before-disconnect",
    );
    fixture
        .wait(|_| std::fs::read_to_string("/tmp/rex-before-disconnect").is_ok_and(|s| s == "kept"));
    // Only terminate the attach process for this block in the fixture PID namespace.
    let pid = rex_attach_pid(block).expect("the live Rex pane attach process");
    assert!(
        Command::new("/bin/kill")
            .args(["-TERM", &pid])
            .status()
            .unwrap()
            .success()
    );
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.error.is_none()
                && w.panes
                    .iter()
                    .any(|p| p.presentation_id == first && p.focused && p.error.is_some())
        })
    });
    assert!(
        fixture
            .workspace
            .send_key(KeyInput::text("ignored", Modifiers::default()))
            .is_err()
    );
    fixture.workspace.reconnect_rex_pane(first).unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.panes
                .iter()
                .any(|p| p.id == block && p.focused && !p.connecting && p.error.is_none())
        }) && fixture.terminal_text().contains("$ ")
    });
    rex_probe(
        fixture,
        "printf '%s' \"$rex_saved\" > /tmp/rex-after-disconnect",
    );
    fixture.wait(|s| {
        std::fs::read_to_string("/tmp/rex-after-disconnect").is_ok_and(|s| s == "kept")
            && s.rex_window().is_some_and(|w| {
                w.panes.len() == 2
                    && w.panes
                        .iter()
                        .any(|p| p.presentation_id == other && p.error.is_none())
            })
    });
}

fn rex_probe(fixture: &Fixture, text: &str) {
    fixture
        .workspace
        .send_key(KeyInput::text(text, Modifiers::default()))
        .unwrap();
    fixture
        .workspace
        .send_key(KeyInput::named(NamedKey::Enter, Modifiers::default()))
        .unwrap();
}

fn resize_with_full_input_queue(fixture: &Fixture) {
    use workspace::{MouseAction, MouseInput};

    // An unsafe paste suspends input consumption without stopping the client.
    fixture
        .workspace
        .send_key(KeyInput::paste("echo first\necho second"))
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    'confirmation: loop {
        for event in fixture.workspace.drain_events().0 {
            match event {
                WorkspaceEvent::ConfirmPaste => break 'confirmation,
                WorkspaceEvent::Error(message) => panic!("{message}"),
                _ => {}
            }
        }
        assert!(Instant::now() < deadline, "missing paste confirmation");
        thread::sleep(Duration::from_millis(20));
    }
    let refusal = (0..1024)
        .find_map(|_| fixture.workspace.copy_terminal_selection().err())
        .expect("input queue must fill while paste is held");
    assert!(refusal.is_backpressure());
    fixture
        .workspace
        .send_mouse(MouseInput {
            action: MouseAction::Move(None),
            column: 2,
            row: 3,
            modifiers: Modifiers::default(),
            click_count: 0,
        })
        .unwrap();

    fixture
        .workspace
        .resize_rex_window(900.0, 540.0, 10.0, 20.0)
        .unwrap();
    fixture
        .workspace
        .resize_rex_window(1000.0, 600.0, 10.0, 20.0)
        .unwrap();
    fixture.workspace.zoom_rex_pane().unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            assert!(
                w.error.is_none(),
                "resize disconnected the window: {:?}",
                w.error
            );
            w.panes
                .iter()
                .any(|p| p.focused && (p.rect.width - 1000.0).abs() < 0.01)
        })
    });
    fixture.workspace.zoom_rex_pane().unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.dividers.len() == 1
                && w.panes.iter().all(|p| p.rect.width > 0.0)
                && w.panes.iter().filter(|p| !p.focused).any(|p| {
                    let size = p.surface.load().size();
                    size.columns() == 49 && size.rows() == 28
                })
        })
    });
    fixture.workspace.cancel_paste();

    // No further size or layout request: the pump must deliver the latest
    // size to the stalled worker as soon as it can accept it.
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.error.is_none()
                && w.panes.len() == 2
                && w.panes.iter().all(|p| {
                    let frame = p.surface.load();
                    p.error.is_none() && frame.size().columns() == 49 && frame.size().rows() == 28
                })
        })
    });
}

#[test]
#[allow(
    clippy::too_many_lines,
    reason = "Keep the same SSH connections through saturation and reconnect."
)]
#[ignore = "requires a Rex server executable; run make rust-test-rex-live"]
fn large_rex_window_keeps_ssh_capacity_and_isolates_pane_startup_failure() {
    let Some(fixture) = Fixture::isolated(
        "native_ssh::rex::large_rex_window_keeps_ssh_capacity_and_isolates_pane_startup_failure",
    ) else {
        return;
    };
    let _server = server(&fixture);
    let created = rex(
        &fixture,
        &[
            "new",
            "Studio",
            "--window",
            "Work",
            "--json",
            "--shell=none",
            "--",
            "/bin/sh",
        ],
    );
    let window = created["initial_windows"][0]["window_id"].as_str().unwrap();
    let mut blocks = vec![
        created["initial_windows"][0]["block_ids"][0]
            .as_str()
            .unwrap()
            .to_owned(),
    ];
    for i in 0..11 {
        let added = rex(
            &fixture,
            &[
                "run",
                "--block",
                &blocks[i],
                "--split",
                if i % 2 == 0 { "right" } else { "below" },
                "--json",
                "--shell=none",
                "--",
                "/bin/sh",
            ],
        );
        blocks.push(
            added["block_ids"][0]
                .as_str()
                .unwrap_or_else(|| panic!("Rex returned no block ID: {added}"))
                .to_owned(),
        );
    }
    let session = created["session_id"].as_str().unwrap();
    rex(
        &fixture,
        &[
            "api",
            "call",
            "--session",
            session,
            "session.new_layer",
            &serde_json::json!({
                "window_id": window,
                "bounds": [0.15, 0.15, 0.5, 0.5],
                "focus": true,
                "layout": {"block": {"flavor": "com.superlogical.terminal.shell"}},
            })
            .to_string(),
        ],
    );
    let view = gui_view(&fixture, window);
    let focused = view["view"]["windows"][0]["focused_block_id"]
        .as_str()
        .unwrap();
    assert!(!blocks.iter().any(|id| id == focused));
    fixture.connect();
    fixture.wait(|s| {
        s.hosts()
            .iter()
            .any(|h| h.rex_windows().iter().any(|w| w.id == window))
    });
    fixture.workspace.select_host(&fixture.host_id).unwrap();
    fixture.attach("review", "retained-before-many-panes");
    fixture
        .workspace
        .switch_session(&SessionSelection::rex(
            &fixture.host_id,
            &fixture.endpoint,
            window,
        ))
        .unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.error.is_none()
                && w.panes.len() == blocks.len()
                && w.panes.iter().any(|p| p.focused)
                && w.panes.iter().all(|p| !p.connecting && p.error.is_none())
                && blocks.iter().all(|id| rex_attach_pid(id).is_some())
        })
    });
    let before = fixture.workspace.snapshot();
    let original = &before.rex_window().unwrap().panes;

    let other = fixture.open_scene();
    other.workspace.select_host(&fixture.host_id).unwrap();
    other.attach("notes 'one'", "while-rex-holds-twelve-panes");

    // Change the route for new SSH leases only. The reviewed connections
    // already in use can still carry layout updates and terminal input.
    let config = fixture.root.join("home/.ssh/config");
    let reviewed = std::fs::read_to_string(&config).unwrap();
    let changed = reviewed.replace("User ghosthub", "User wrong-account");
    assert_ne!(changed, reviewed);
    std::fs::write(&config, changed).unwrap();
    fixture.workspace.split_rex_pane(false).unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.error.is_none()
                && w.panes.len() == blocks.len() + 1
                && w.panes.iter().any(|p| {
                    p.error
                        .as_deref()
                        .is_some_and(|e| e.contains("SSH route changed"))
                })
        })
    });
    std::fs::write(config, reviewed).unwrap();
    let snapshot = fixture.workspace.snapshot();
    let failed = snapshot
        .rex_window()
        .unwrap()
        .panes
        .iter()
        .find(|p| p.error.is_some())
        .unwrap();
    fixture
        .workspace
        .reconnect_rex_pane(failed.presentation_id)
        .unwrap();
    fixture.wait(|s| {
        s.rex_window().is_some_and(|w| {
            w.error.is_none()
                && w.panes.len() == blocks.len() + 1
                && w.panes.iter().all(|p| !p.connecting && p.error.is_none())
                && rex_attach_pid(&failed.id).is_some()
                && original.iter().all(|p| {
                    w.panes
                        .iter()
                        .any(|now| now.presentation_id == p.presentation_id)
                })
        })
    });
    other.workspace.close();
    fixture.workspace.close();
}

fn rex_attach_pid(block: &str) -> Option<String> {
    std::fs::read_dir("/proc")
        .unwrap()
        .filter_map(Result::ok)
        .find_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            name.parse::<u32>().ok()?;
            let command = std::fs::read(entry.path().join("cmdline")).ok()?;
            let args: Vec<_> = command.split(|b| *b == 0).collect();
            (args.len() == 5
                && args[0].ends_with(b"/kwt")
                && args[1..4] == [b"rex".as_slice(), b"attach", block.as_bytes()])
            .then_some(name)
        })
}
