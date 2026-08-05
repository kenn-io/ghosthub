//! WSL host resolution and tmux inventory.

use std::ffi::{OsStr, OsString};
use std::io;
use std::process::Command;

pub use model::DiagnosticKind as HostErrorKind;

mod wsl;

pub use wsl::{HostError, HostSnapshot, WslConfig, WslEndpoint, WslHost, WslRuntimeIdentity};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

pub trait CommandRunner: Send + Sync {
    /// Run one executable with exact argv and capture all output.
    ///
    /// # Errors
    ///
    /// Returns the platform spawn or wait error.
    fn run(&self, program: &OsStr, args: &[OsString]) -> io::Result<CommandOutput>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct StdCommandRunner;

impl CommandRunner for StdCommandRunner {
    fn run(&self, program: &OsStr, args: &[OsString]) -> io::Result<CommandOutput> {
        let output = Command::new(program).args(args).output()?;
        Ok(CommandOutput {
            status: output.status.code().unwrap_or(-1),
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }
}
