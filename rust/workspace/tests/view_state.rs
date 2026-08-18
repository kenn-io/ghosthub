use std::{
    fs,
    sync::atomic::{AtomicU64, Ordering},
};

use config::{ApplicationConfig, Roots, TerminalAppearance};
use host::{WslConfig, WslExecutable};
use model::DiagnosticKind;
use workspace::{
    Appearance, AppearanceSettingsDraft, HostConnectionState, HostDiagnostic, HostItem,
    SessionItem, Workspace, WorkspaceContent, WorkspaceSnapshot, WslHostSpec,
};

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[test]
fn host_failure_is_scoped_beside_the_application_shell() {
    let host = HostItem::wsl(
        "Default distro",
        None,
        HostConnectionState::Unavailable,
        Vec::new(),
        Some(HostDiagnostic::new(
            DiagnosticKind::Timeout,
            "WSL host refresh timed out",
        )),
    );
    let snapshot = WorkspaceSnapshot::shell(Appearance::default(), vec![host]);

    assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
    assert_eq!(snapshot.selected_host(), Some("wsl"));
    assert_eq!(snapshot.hosts().len(), 1);
    assert_eq!(
        snapshot.hosts()[0].connection(),
        HostConnectionState::Unavailable
    );
    assert_eq!(
        snapshot.hosts()[0]
            .diagnostic()
            .expect("host diagnostic")
            .kind(),
        DiagnosticKind::Timeout
    );
}

#[test]
fn ready_host_may_have_an_empty_session_inventory() {
    let host = HostItem::wsl(
        "Ubuntu",
        Some("/run/user/1000/tmux".to_owned()),
        HostConnectionState::Ready,
        Vec::new(),
        None,
    );
    let snapshot = WorkspaceSnapshot::shell(Appearance::default(), vec![host]);

    assert_eq!(snapshot.hosts()[0].connection(), HostConnectionState::Ready);
    assert!(snapshot.hosts()[0].sessions().is_empty());
    assert_eq!(
        snapshot.hosts()[0].socket_directory(),
        Some("/run/user/1000/tmux")
    );
}

#[test]
fn application_workspace_does_not_connect_wsl_during_construction() {
    let spec = WslHostSpec::available(
        WslConfig::with_distro("Ubuntu").expect("valid WSL config"),
        WslExecutable::from_absolute(r"C:\Windows\System32\wsl.exe").expect("absolute WSL path"),
    );

    let workspace = Workspace::application(TerminalAppearance::default(), Some(spec));

    assert!(matches!(
        workspace.snapshot().content(),
        WorkspaceContent::Shell
    ));
    assert_eq!(
        workspace.snapshot().hosts()[0].connection(),
        HostConnectionState::Disconnected
    );
}

#[test]
fn connecting_enabled_hosts_without_a_host_is_a_no_op() {
    let workspace = Workspace::application(TerminalAppearance::default(), None);

    workspace
        .connect_enabled_hosts()
        .expect("no enabled hosts is successful");

    assert!(workspace.snapshot().hosts().is_empty());
}

#[test]
fn projects_config_and_inventory_into_ui_only_values() {
    let snapshot = WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("editor", 1)],
    );

    assert_eq!(snapshot.appearance().font_family(), "Cascadia Mono");
    let WorkspaceContent::Ready { endpoint, sessions } = snapshot.content() else {
        panic!("expected ready workspace");
    };
    assert_eq!(endpoint, "Ubuntu");
    assert_eq!(sessions[0].name(), "editor");
    assert_eq!(sessions[0].attached_clients(), 1);
}

#[test]
fn preview_workspace_cannot_accidentally_start_host_discovery() {
    let workspace = workspace::Workspace::preview(WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        Vec::new(),
    ));

    assert_eq!(
        workspace
            .refresh()
            .expect_err("preview must stay inert")
            .to_string(),
        "preview workspace cannot refresh WSL"
    );
}

#[test]
fn startup_configuration_errors_are_visible_without_starting_a_host() {
    let workspace = Workspace::startup_error(
        TerminalAppearance::default(),
        "configuration error: invalid color",
    );

    match workspace.snapshot().content() {
        WorkspaceContent::Error { message } => {
            assert_eq!(message, "configuration error: invalid color");
        }
        _ => panic!("startup error must be visible"),
    }
}

#[test]
fn saved_appearance_is_persisted_and_published_without_rebuilding_hosts() {
    let root = std::env::temp_dir().join(format!(
        "ghosthub-workspace-appearance-{}-{}",
        std::process::id(),
        TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let value = root.to_string_lossy().into_owned();
    let roots = Roots {
        ghosthub_home: value.clone(),
        config: value.clone(),
        state: value.clone(),
        helpers: value,
    };
    let workspace = Workspace::application_with_remote_hosts(
        TerminalAppearance::default(),
        None,
        Vec::new(),
        ApplicationConfig::default(),
        roots.clone(),
        None,
        None,
    );

    workspace
        .save_appearance(&AppearanceSettingsDraft {
            font_family: "Iosevka Term".to_owned(),
            font_size: "16".to_owned(),
            background: "#102030".to_owned(),
            foreground: "#f0e0d0".to_owned(),
        })
        .expect("save appearance");

    let snapshot = workspace.snapshot();
    assert_eq!(snapshot.appearance().font_family(), "Iosevka Term");
    assert_eq!(snapshot.appearance().font_size(), 16);
    assert_eq!(snapshot.appearance().background(), 0x10_20_30);
    assert_eq!(snapshot.appearance().foreground(), 0xf0_e0_d0);
    assert!(snapshot.hosts().is_empty());
    assert_eq!(
        ApplicationConfig::load(&roots)
            .expect("reload application config")
            .terminal()
            .font_family(),
        "Iosevka Term"
    );
    fs::remove_dir_all(root).expect("remove temporary config root");
}
