//! WSL host resolution and tmux inventory.

use std::ffi::{OsStr, OsString};
use std::io::{self, Read};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

pub use model::DiagnosticKind as HostErrorKind;

mod wsl;

pub use wsl::{HostError, HostSnapshot, WslConfig, WslEndpoint, WslHost, WslRuntimeIdentity};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Clone, Debug, Default)]
pub struct CancellationToken(Arc<AtomicBool>);

impl CancellationToken {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    #[must_use]
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

pub trait CommandRunner: Send + Sync {
    /// Run one executable with exact argv and capture all output.
    ///
    /// # Errors
    ///
    /// Returns the platform spawn or wait error.
    fn run(
        &self,
        program: &OsStr,
        args: &[OsString],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct StdCommandRunner;

impl CommandRunner for StdCommandRunner {
    fn run(
        &self,
        program: &OsStr,
        args: &[OsString],
        cancellation: &CancellationToken,
        timeout: Duration,
    ) -> io::Result<CommandOutput> {
        let mut child = Command::new(program)
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let stdout = child.stdout.take().ok_or_else(|| {
            io::Error::new(io::ErrorKind::BrokenPipe, "child stdout was not captured")
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            io::Error::new(io::ErrorKind::BrokenPipe, "child stderr was not captured")
        })?;
        let stdout = thread::spawn(move || read_all(stdout));
        let stderr = thread::spawn(move || read_all(stderr));
        let deadline = Instant::now() + timeout;
        let status = loop {
            if cancellation.is_cancelled() {
                let _ignored = child.kill();
                let _ignored = child.wait();
                return Err(io::Error::new(
                    io::ErrorKind::Interrupted,
                    "command cancelled",
                ));
            }
            if Instant::now() >= deadline {
                let _ignored = child.kill();
                let _ignored = child.wait();
                return Err(io::Error::new(io::ErrorKind::TimedOut, "command timed out"));
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            thread::sleep(Duration::from_millis(10));
        };
        Ok(CommandOutput {
            status: status.code().unwrap_or(-1),
            stdout: join_reader(stdout)?,
            stderr: join_reader(stderr)?,
        })
    }
}

fn read_all(mut reader: impl Read) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn join_reader(reader: thread::JoinHandle<io::Result<Vec<u8>>>) -> io::Result<Vec<u8>> {
    reader
        .join()
        .map_err(|_| io::Error::other("command output reader panicked"))?
}
