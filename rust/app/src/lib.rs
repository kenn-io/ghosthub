//! Composition root for the Rust Ghosthub application.

use model::PortStatus;

#[cfg(target_os = "linux")]
const PLATFORM_NAME: &str = "Linux";
#[cfg(target_os = "windows")]
const PLATFORM_NAME: &str = "Windows";

#[must_use]
pub const fn bootstrap_status() -> PortStatus {
    PortStatus::new(PLATFORM_NAME)
}

pub fn run() {
    ui::run(bootstrap_status());
}
