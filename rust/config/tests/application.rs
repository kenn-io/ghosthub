use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

use config::{ApplicationConfig, Roots};

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
    assert_eq!(loaded.terminal().background(), 0x0c_0f_14);
    assert_eq!(loaded.terminal().foreground(), 0xd8_de_e9);
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
