//! Composition root for the Rust Ghosthub application.

#[cfg(not(windows))]
use host::SshExecutable;
use host::{RemoteTmuxConfig, SshTarget};
use model::DiagnosticKind;
use model::PortStatus;
use workspace::{RemoteHostSpec, Workspace, WslHostSpec};

const KWT_BYTES: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/kwt"));
const KWT_CONTROLLER_BYTES: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/kwt-controller.exe"));

#[cfg(target_os = "linux")]
const PLATFORM_NAME: &str = "Linux";
#[cfg(target_os = "windows")]
const PLATFORM_NAME: &str = "Windows";

#[must_use]
pub const fn bootstrap_status() -> PortStatus {
    PortStatus::new(PLATFORM_NAME)
}

pub fn run() {
    let workspace = match config::ApplicationConfig::current_roots() {
        Ok(roots) => match config::ApplicationConfig::load(&roots) {
            Ok(settings) => match workspace_for(&settings, roots, &host::SystemWslPresence) {
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
    roots: config::Roots,
    presence: &dyn host::WslPresence,
) -> Result<Workspace, String> {
    let (wsl, terminal) = runtime_settings(settings).map_err(|error| error.to_string())?;
    let spec = match presence.resolve() {
        Ok(Some(executable)) => Some(WslHostSpec::available(wsl, executable)),
        Ok(None) => None,
        Err(error) => Some(WslHostSpec::unavailable(wsl, &error)),
    };
    #[cfg(windows)]
    let wsl_transport_available = spec.as_ref().is_some_and(WslHostSpec::is_available);
    #[cfg(not(windows))]
    let controller = activate_bundled_kwt_controller(std::path::Path::new(&roots.helpers));
    #[cfg(not(windows))]
    let ssh = SshExecutable::system();
    let remote_specs = settings
        .ssh_hosts()
        .iter()
        .map(|configured| {
            let target = SshTarget::new(
                configured.hostname(),
                configured.user().map(str::to_owned),
                configured.port(),
            )
            .map_err(|error| error.to_string())?;
            let remote = RemoteTmuxConfig::new(
                configured.id(),
                configured.name(),
                target,
                configured.tmux_binary(),
                configured.socket_directory().map(str::to_owned),
            )
            .map_err(|error| error.to_string())?;
            #[cfg(windows)]
            let spec = if wsl_transport_available {
                RemoteHostSpec::wsl(remote)
            } else {
                RemoteHostSpec::unavailable(
                    remote,
                    DiagnosticKind::UnsupportedEnvironment,
                    "SSH hosts require an available WSL distro on Windows",
                )
            };
            #[cfg(not(windows))]
            let spec = match (&controller, &ssh) {
                (Ok(Some(controller)), Ok(ssh)) => {
                    RemoteHostSpec::available(remote, controller.clone(), ssh.clone())
                }
                (Err(error), _) => RemoteHostSpec::unavailable(
                    remote,
                    error.kind(),
                    format!("SSH controller unavailable: {error}"),
                ),
                (Ok(None), _) => RemoteHostSpec::unavailable(
                    remote,
                    DiagnosticKind::ExecutableNotFound,
                    "This build does not contain the pinned KWT SSH controller",
                ),
                (_, Err(error)) => RemoteHostSpec::unavailable(
                    remote,
                    error.kind(),
                    format!("OpenSSH unavailable: {error}"),
                ),
            };
            Ok(spec)
        })
        .collect::<Result<Vec<_>, String>>()?;
    #[cfg(windows)]
    let (controller, ssh) = (None, None);
    #[cfg(not(windows))]
    let (controller, ssh) = (controller.ok().flatten(), ssh.ok());
    Ok(Workspace::application_with_remote_hosts(
        terminal,
        spec,
        remote_specs,
        settings.clone(),
        roots,
        controller,
        ssh,
    ))
}

fn runtime_settings(
    settings: &config::ApplicationConfig,
) -> Result<(host::WslConfig, config::TerminalAppearance), host::HostError> {
    let wsl = settings.wsl();
    let mut wsl = host::WslConfig::configured(
        wsl.distro().map(str::to_owned),
        wsl.tmux_binary(),
        wsl.socket_directory().map(str::to_owned),
    )?;
    if let Some(bundle) = bundled_kwt() {
        wsl = wsl.with_kwt_bundle(bundle);
    }
    Ok((wsl, settings.terminal().clone()))
}

fn bundled_kwt() -> Option<host::KwtBundle> {
    if env!("GHOSTHUB_KWT_AVAILABLE") != "true" {
        return None;
    }
    host::KwtBundle::new(
        env!("GHOSTHUB_KWT_REVISION"),
        env!("GHOSTHUB_KWT_SHA256"),
        KWT_BYTES,
    )
    .map(Some)
    .expect("build script emitted valid KWT bundle metadata")
}

/// Return the revision-pinned native KWT controller bundle used to resolve
/// SSH routes and own connection leases.
///
/// # Panics
///
/// Panics only when build-script-provided bundle metadata is internally
/// inconsistent. The build script validates the same values before compiling
/// this crate.
#[must_use]
pub fn bundled_kwt_controller() -> Option<host::KwtBundle> {
    if env!("GHOSTHUB_KWT_CONTROLLER_AVAILABLE") != "true" {
        return None;
    }
    host::KwtBundle::new(
        env!("GHOSTHUB_KWT_REVISION"),
        env!("GHOSTHUB_KWT_CONTROLLER_SHA256"),
        KWT_CONTROLLER_BYTES,
    )
    .map(Some)
    .expect("build script emitted valid native KWT controller metadata")
}

/// Activate the bundled controller under an explicit, already-resolved local
/// helper root.
///
/// # Errors
///
/// Returns an error when the content-addressed helper cannot be installed or
/// does not match the packaged digest.
pub fn activate_bundled_kwt_controller(
    helper_root: &std::path::Path,
) -> Result<Option<host::KwtSshExecutable>, host::SshError> {
    bundled_kwt_controller()
        .as_ref()
        .map(|bundle| host::KwtSshExecutable::activate(bundle, helper_root))
        .transpose()
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
        let root =
            std::env::temp_dir().join(format!("ghosthub-app-test-roots-{}", std::process::id()));
        let roots = config::Roots {
            ghosthub_home: root.display().to_string(),
            config: root.join("config").display().to_string(),
            state: root.join("state").display().to_string(),
            helpers: root.join("helpers").display().to_string(),
        };

        let workspace =
            super::workspace_for(&settings, roots, &PresentWsl).expect("valid workspace");

        let snapshot = workspace.snapshot();
        assert!(matches!(snapshot.content(), WorkspaceContent::Shell));
        assert_eq!(snapshot.hosts().len(), 1);
        assert_eq!(
            snapshot.hosts()[0].connection(),
            HostConnectionState::Disconnected
        );
        if root.exists() {
            std::fs::remove_dir_all(root).expect("remove app test roots");
        }
    }

    #[cfg(windows)]
    #[test]
    fn configured_ssh_hosts_use_the_available_wsl_transport() {
        let settings = ApplicationConfig::from_toml(
            r#"
                [[ssh-host]]
                name = "Studio"
                hostname = "studio.example"
            "#,
        )
        .expect("valid SSH host configuration");
        let root = std::env::temp_dir().join(format!(
            "ghosthub-app-ssh-test-roots-{}",
            std::process::id()
        ));
        let roots = config::Roots {
            ghosthub_home: root.display().to_string(),
            config: root.join("config").display().to_string(),
            state: root.join("state").display().to_string(),
            helpers: root.join("helpers").display().to_string(),
        };

        let workspace =
            super::workspace_for(&settings, roots, &PresentWsl).expect("valid workspace");
        let snapshot = workspace.snapshot();
        let remote = snapshot
            .hosts()
            .iter()
            .find(|host| host.is_ssh() && host.name() == "Studio")
            .expect("configured SSH host");

        assert_eq!(remote.connection(), HostConnectionState::Disconnected);
        assert!(remote.diagnostic().is_none());
        if root.exists() {
            std::fs::remove_dir_all(root).expect("remove app SSH test roots");
        }
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

        let mut expected = WslConfig::configured(
            Some("Ubuntu Dev".to_owned()),
            "/opt/tmux",
            Some("/run/user/1000/tmux".to_owned()),
        )
        .expect("valid WSL settings");
        if let Some(bundle) = super::bundled_kwt() {
            expected = expected.with_kwt_bundle(bundle);
        }
        assert_eq!(wsl, expected);
        assert_eq!(terminal.font_family(), "Iosevka Term");
        assert_eq!(terminal.font_size(), 17);
        assert_eq!(terminal.background(), 0x01_02_03);
        assert_eq!(terminal.foreground(), 0xfe_fd_fc);
        assert!(!terminal.allow_remote_clipboard_write());
    }
}
