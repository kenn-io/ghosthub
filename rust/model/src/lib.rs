//! Pure domain values for the Rust Ghosthub application.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DiagnosticKind {
    ExecutableNotFound,
    MalformedOutput,
    PermissionDenied,
    Timeout,
    Transport,
    UnsupportedEnvironment,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PortStatus {
    platform: &'static str,
}

impl PortStatus {
    #[must_use]
    pub const fn new(platform: &'static str) -> Self {
        Self { platform }
    }

    #[must_use]
    pub const fn platform(&self) -> &'static str {
        self.platform
    }

    #[must_use]
    pub fn headline(&self) -> String {
        format!("Ghosthub Rust port · {}", self.platform)
    }
}
