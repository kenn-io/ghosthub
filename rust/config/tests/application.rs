use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

use config::{ApplicationConfig, Roots, SshHostSettings, TerminalAppearance, TerminalTheme};

static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

#[test]
fn missing_application_config_uses_documented_defaults() {
    let root = temporary_root("missing");
    let roots = roots_at(&root);

    let loaded = ApplicationConfig::load(&roots).expect("missing config uses defaults");

    assert_eq!(loaded.wsl().distro(), None);
    assert_eq!(loaded.wsl().tmux_binary(), "/usr/bin/tmux");
    assert_eq!(loaded.wsl().socket_directory(), None);
    assert_eq!(loaded.terminal().font_family(), "Cascadia Mono");
    assert_eq!(loaded.terminal().font_size(), 14);
    assert_eq!(loaded.terminal().theme(), TerminalTheme::ClearDark);
    assert_eq!(loaded.terminal().background(), 0x21_27_34);
    assert_eq!(loaded.terminal().foreground(), 0xe6_e6_e6);
    assert!(loaded.terminal().allow_remote_clipboard_write());
}

#[test]
fn application_config_projects_all_read_only_settings() {
    let parsed = ApplicationConfig::from_toml(
        r##"
            [wsl]
            distro = "Ubuntu Dev"
            tmux-binary = "/opt/tmux/bin/tmux"
            socket-directory = "/run/user/1000/tmux"

            [terminal]
            font-family = "Iosevka Term"
            font-size = 16
            background = "#102030"
            foreground = "#f0e0d0"
            clipboard-write = false
        "##,
    )
    .expect("parse complete application config");

    assert_eq!(parsed.wsl().distro(), Some("Ubuntu Dev"));
    assert_eq!(parsed.wsl().tmux_binary(), "/opt/tmux/bin/tmux");
    assert_eq!(parsed.wsl().socket_directory(), Some("/run/user/1000/tmux"));
    assert_eq!(parsed.terminal().font_family(), "Iosevka Term");
    assert_eq!(parsed.terminal().font_size(), 16);
    assert_eq!(parsed.terminal().background(), 0x10_20_30);
    assert_eq!(parsed.terminal().foreground(), 0xf0_e0_d0);
    assert!(!parsed.terminal().allow_remote_clipboard_write());
}

#[test]
fn present_application_config_is_loaded_from_the_resolved_config_root() {
    let root = temporary_root("present");
    fs::create_dir_all(&root).expect("create temporary config root");
    fs::write(
        root.join("config.toml"),
        "[wsl]\ndistro = \"Ubuntu-Test\"\n",
    )
    .expect("write application config");

    let loaded = ApplicationConfig::load(&roots_at(&root)).expect("load application config");

    assert_eq!(loaded.wsl().distro(), Some("Ubuntu-Test"));
    fs::remove_dir_all(root).expect("remove temporary config root");
}

#[test]
fn malformed_or_unknown_configuration_is_rejected() {
    for contents in [
        "[wsl\ndistro = \"Ubuntu\"",
        "[wsl]\nunknown = true\n",
        "[unknown]\nvalue = true\n",
    ] {
        assert!(
            ApplicationConfig::from_toml(contents).is_err(),
            "must reject {contents:?}"
        );
    }
}

#[test]
fn invalid_runtime_values_are_rejected_before_workspace_creation() {
    for contents in [
        "[wsl]\ndistro = \"\"\n",
        "[wsl]\ntmux-binary = \"usr/bin/tmux\"\n",
        "[wsl]\nsocket-directory = \"tmp/tmux\"\n",
        "[terminal]\nfont-family = \"\"\n",
        "[terminal]\nfont-size = 0\n",
        "[terminal]\nbackground = \"112233\"\n",
        "[terminal]\nforeground = \"#xyzxyz\"\n",
    ] {
        assert!(
            ApplicationConfig::from_toml(contents).is_err(),
            "must reject {contents:?}"
        );
    }
}

#[test]
fn ssh_hosts_round_trip_through_the_application_config() {
    let root = temporary_root("ssh-round-trip");
    let roots = roots_at(&root);
    let mut config = ApplicationConfig::default();
    let host = SshHostSettings::new(
        "Studio",
        "studio.example",
        Some("wesm".to_owned()),
        Some(2222),
        "/opt/homebrew/bin/tmux",
        Some("/run/user/501/tmux".to_owned()),
    )
    .expect("valid SSH host");

    config
        .replace_ssh_hosts(&roots, vec![host])
        .expect("persist SSH host");
    let loaded = ApplicationConfig::load(&roots).expect("reload SSH host");

    assert_eq!(loaded.ssh_hosts().len(), 1);
    let loaded = &loaded.ssh_hosts()[0];
    assert_eq!(loaded.name(), "Studio");
    assert_eq!(loaded.hostname(), "studio.example");
    assert_eq!(loaded.user(), Some("wesm"));
    assert_eq!(loaded.port(), Some(2222));
    assert_eq!(loaded.tmux_binary(), "/opt/homebrew/bin/tmux");
    assert_eq!(loaded.socket_directory(), Some("/run/user/501/tmux"));
    fs::remove_dir_all(root).expect("remove temporary config root");
}

#[test]
fn ssh_hosts_discover_tmux_automatically_by_default() {
    let parsed = ApplicationConfig::from_toml(
        r#"
            [[ssh-host]]
            name = "Studio"
            hostname = "studio.example"
        "#,
    )
    .expect("parse automatic SSH host");

    assert_eq!(parsed.ssh_hosts()[0].tmux_binary(), "");

    let explicit = ApplicationConfig::from_toml(
        r#"
            [[ssh-host]]
            name = "Studio"
            hostname = "studio.example"
            tmux-binary = "/usr/bin/tmux"
        "#,
    )
    .expect("parse explicit Linux path");

    assert_eq!(explicit.ssh_hosts()[0].tmux_binary(), "/usr/bin/tmux");
}

#[test]
fn saving_over_an_existing_config_replaces_it_without_temporary_files() {
    let root = temporary_root("atomic-replace");
    let roots = roots_at(&root);
    let mut config = ApplicationConfig::default();
    config.save(&roots).expect("persist initial config");
    let host = SshHostSettings::new(
        "Studio",
        "studio.example",
        None,
        None,
        "/usr/bin/tmux",
        None,
    )
    .expect("valid SSH host");

    config
        .replace_ssh_hosts(&roots, vec![host])
        .expect("atomically replace existing config");

    let loaded = ApplicationConfig::load(&roots).expect("load replaced config");
    assert_eq!(loaded.ssh_hosts()[0].hostname(), "studio.example");
    assert_eq!(loaded.ssh_hosts()[0].tmux_binary(), "/usr/bin/tmux");
    let entries = fs::read_dir(&root)
        .expect("read config directory")
        .collect::<Result<Vec<_>, _>>()
        .expect("read config entries");
    assert_eq!(entries.len(), 1, "temporary config files must be removed");
    assert_eq!(entries[0].file_name(), "config.toml");
    fs::remove_dir_all(root).expect("remove temporary config root");
}

#[test]
fn duplicate_ssh_endpoints_are_rejected_before_persistence() {
    let root = temporary_root("ssh-duplicates");
    let roots = roots_at(&root);
    let mut config = ApplicationConfig::default();
    let first = SshHostSettings::new(
        "Studio",
        "studio.example",
        Some("wesm".to_owned()),
        None,
        "/usr/bin/tmux",
        None,
    )
    .expect("valid SSH host");
    let second = SshHostSettings::new(
        "Duplicate",
        "studio.example",
        Some("wesm".to_owned()),
        None,
        "/usr/local/bin/tmux",
        None,
    )
    .expect("valid SSH host");

    let error = config
        .replace_ssh_hosts(&roots, vec![first, second])
        .expect_err("duplicate endpoint must fail");

    assert!(error.to_string().contains("configured more than once"));
    assert!(!root.join("config.toml").exists());
}

#[test]
fn failed_ssh_host_persistence_preserves_the_loaded_configuration() {
    let root = temporary_root("ssh-write-failure");
    fs::write(&root, "not a directory").expect("create blocking config file");
    let roots = roots_at(&root);
    let mut config = ApplicationConfig::default();
    let host = SshHostSettings::new(
        "Studio",
        "studio.example",
        Some("wesm".to_owned()),
        None,
        "/usr/bin/tmux",
        None,
    )
    .expect("valid SSH host");

    let error = config
        .replace_ssh_hosts(&roots, vec![host])
        .expect_err("persistence must fail when the config root is a file");

    assert!(error.to_string().contains("create"));
    assert!(
        config.ssh_hosts().is_empty(),
        "failed persistence must not change the in-memory settings"
    );
    fs::remove_file(root).expect("remove blocking config file");
}

#[test]
fn terminal_appearance_round_trips_without_changing_other_settings() {
    let root = temporary_root("appearance-round-trip");
    let roots = roots_at(&root);
    let mut config = ApplicationConfig::from_toml("[wsl]\ndistro = \"Ubuntu\"\n")
        .expect("valid starting configuration");
    let appearance = TerminalAppearance::new("Berkeley Mono", 15, "#111820", "#e4e8ef", false)
        .expect("valid appearance");

    config
        .replace_terminal_appearance(&roots, appearance)
        .expect("persist appearance");
    let loaded = ApplicationConfig::load(&roots).expect("reload appearance");

    assert_eq!(loaded.wsl().distro(), Some("Ubuntu"));
    assert_eq!(loaded.terminal().font_family(), "Berkeley Mono");
    assert_eq!(loaded.terminal().font_size(), 15);
    assert_eq!(loaded.terminal().background(), 0x11_18_20);
    assert_eq!(loaded.terminal().foreground(), 0xe4_e8_ef);
    assert!(!loaded.terminal().allow_remote_clipboard_write());
    fs::remove_dir_all(root).expect("remove temporary config root");
}

#[test]
fn built_in_terminal_theme_round_trips_without_redundant_color_overrides() {
    let root = temporary_root("built-in-appearance-round-trip");
    let roots = roots_at(&root);
    let mut config = ApplicationConfig::default();
    let appearance = TerminalAppearance::themed(
        TerminalTheme::Novel,
        "Cascadia Mono",
        15,
        "#000000",
        "#ffffff",
        true,
    )
    .expect("valid built-in appearance");

    config
        .replace_terminal_appearance(&roots, appearance)
        .expect("persist built-in appearance");
    let contents = fs::read_to_string(root.join("config.toml")).expect("read saved config");
    let loaded = ApplicationConfig::load(&roots).expect("reload built-in appearance");

    assert_eq!(loaded.terminal().theme(), TerminalTheme::Novel);
    assert_eq!(loaded.terminal().background(), 0xdf_db_c3);
    assert_eq!(loaded.terminal().foreground(), 0x4d_2f_2d);
    assert!(contents.contains("theme = \"novel\""));
    assert!(!contents.contains("background ="));
    assert!(!contents.contains("foreground ="));
    fs::remove_dir_all(root).expect("remove temporary config root");
}

#[test]
fn color_only_configuration_is_preserved_as_custom() {
    let config = ApplicationConfig::from_toml(
        "[terminal]\nfont-family = \"Iosevka Term\"\nbackground = \"#102030\"\nforeground = \"#f0e0d0\"\n",
    )
    .expect("load legacy color-only appearance");

    assert_eq!(config.terminal().theme(), TerminalTheme::Custom);
    assert_eq!(config.terminal().background(), 0x10_20_30);
    assert_eq!(config.terminal().foreground(), 0xf0_e0_d0);
}

#[test]
fn failed_appearance_persistence_preserves_the_loaded_configuration() {
    let root = temporary_root("appearance-write-failure");
    fs::write(&root, "not a directory").expect("create blocking config file");
    let roots = roots_at(&root);
    let mut config = ApplicationConfig::default();
    let appearance = TerminalAppearance::new("Berkeley Mono", 15, "#111820", "#e4e8ef", true)
        .expect("valid appearance");

    let error = config
        .replace_terminal_appearance(&roots, appearance)
        .expect_err("persistence must fail when the config root is a file");

    assert!(error.to_string().contains("create"));
    assert_eq!(config.terminal(), &TerminalAppearance::default());
    fs::remove_file(root).expect("remove blocking config file");
}

fn temporary_root(label: &str) -> PathBuf {
    let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "ghosthub-config-{label}-{}-{sequence}",
        std::process::id()
    ))
}

fn roots_at(root: &std::path::Path) -> Roots {
    let value = root.to_string_lossy().into_owned();
    Roots {
        ghosthub_home: value.clone(),
        config: value.clone(),
        state: value.clone(),
        helpers: value,
    }
}
