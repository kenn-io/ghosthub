//! Composition root for the Rust Ghosthub application.

use model::PortStatus;
use workspace::{Workspace, WslHostSpec};

#[cfg(target_os = "linux")]
const PLATFORM_NAME: &str = "Linux";
#[cfg(target_os = "windows")]
const PLATFORM_NAME: &str = "Windows";

#[must_use]
pub const fn bootstrap_status() -> PortStatus {
    PortStatus::new(PLATFORM_NAME)
}

pub fn run() {
    let workspace = match config::ApplicationConfig::load_current() {
        Ok(settings) => match workspace_for(&settings, &host::SystemWslPresence) {
            Ok(workspace) => workspace,
            Err(error) => Workspace::startup_error(
                config::TerminalAppearance::default(),
                format!("Configuration error: {error}"),
            ),
        },
        Err(error) => Workspace::startup_error(
            config::TerminalAppearance::default(),
            format!("Configuration error: {error}"),
        ),
    };
    ui::run(bootstrap_status(), workspace);
}

fn workspace_for(
    settings: &config::ApplicationConfig,
    presence: &dyn host::WslPresence,
) -> Result<Workspace, host::HostError> {
    let (wsl, terminal) = runtime_settings(settings)?;
    let spec = match presence.resolve() {
        Ok(Some(executable)) => Some(WslHostSpec::available(wsl, executable)),
        Ok(None) => None,
        Err(error) => Some(WslHostSpec::unavailable(wsl, &error)),
    };
    Ok(Workspace::application(terminal, spec))
}

fn runtime_settings(
    settings: &config::ApplicationConfig,
) -> Result<(host::WslConfig, config::TerminalAppearance), host::HostError> {
    let wsl = settings.wsl();
    let wsl = host::WslConfig::configured(
        wsl.distro().map(str::to_owned),
        wsl.tmux_binary(),
        wsl.socket_directory().map(str::to_owned),
    )?;
    Ok((wsl, settings.terminal().clone()))
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use config::ApplicationConfig;
    use host::{HostError, WslConfig, WslExecutable, WslPresence};
    use workspace::{HostConnectionState, WorkspaceContent};

    use super::runtime_settings;

    struct PresentWsl;

    impl WslPresence for PresentWsl {
        fn resolve(&self) -> Result<Option<WslExecutable>, HostError> {
            WslExecutable::from_absolute(OsString::from(r"C:\Windows\System32\wsl.exe")).map(Some)
        }
    }

    #[test]
    fn workspace_is_built_before_present_wsl_is_connected() {
        let settings = ApplicationConfig::default();

        let workspace = super::workspace_for(&settings, &PresentWsl).expect("valid workspace");

        let snapshot = workspace.snapshot();
        assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
        assert_eq!(snapshot.hosts().len(), 1);
        assert_eq!(
            snapshot.hosts()[0].connection(),
            HostConnectionState::Disconnected
        );
    }

    #[test]
    fn runtime_settings_preserve_explicit_startup_configuration() {
        let parsed = ApplicationConfig::from_toml(
            r##"
                [wsl]
                distro = "Ubuntu Dev"
                tmux-binary = "/opt/tmux"
                socket-directory = "/run/user/1000/tmux"

                [terminal]
                font-family = "Iosevka Term"
                font-size = 17
                background = "#010203"
                foreground = "#fefdfc"
                clipboard-write = false
            "##,
        )
        .expect("valid startup configuration");

        let (wsl, terminal) = runtime_settings(&parsed).expect("project runtime settings");

        assert_eq!(
            wsl,
            WslConfig::configured(
                Some("Ubuntu Dev".to_owned()),
                "/opt/tmux",
                Some("/run/user/1000/tmux".to_owned()),
            )
            .expect("valid WSL settings")
        );
        assert_eq!(terminal.font_family(), "Iosevka Term");
        assert_eq!(terminal.font_size(), 17);
        assert_eq!(terminal.background(), 0x01_02_03);
        assert_eq!(terminal.foreground(), 0xfe_fd_fc);
        assert!(!terminal.allow_remote_clipboard_write());
    }
}
