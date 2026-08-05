//! Composition root for the Rust Ghosthub application.

use model::PortStatus;
use workspace::Workspace;

#[cfg(target_os = "linux")]
const PLATFORM_NAME: &str = "Linux";
#[cfg(target_os = "windows")]
const PLATFORM_NAME: &str = "Windows";

#[must_use]
pub const fn bootstrap_status() -> PortStatus {
    PortStatus::new(PLATFORM_NAME)
}

pub fn run() {
    let workspace = Workspace::start_wsl(
        host::WslConfig::default(),
        config::TerminalAppearance::default(),
    );
    ui::run(bootstrap_status(), workspace);
}
