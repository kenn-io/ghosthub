//! Composition root for the Rust Ghosthub application.

use model::PortStatus;

#[must_use]
pub const fn bootstrap_status() -> PortStatus {
    PortStatus::new(std::env::consts::OS)
}

pub fn run() {
    ui::run(bootstrap_status());
}
