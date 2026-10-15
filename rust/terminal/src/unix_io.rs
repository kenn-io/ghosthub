//! Interruptible I/O for a PTY whose input queue can outlive its slave.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, BorrowedFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use portable_pty::MasterPty;

pub(crate) struct PtyIo {
    file: File,
    stopped: Arc<AtomicBool>,
}

impl PtyIo {
    #[allow(unsafe_code)]
    pub(crate) fn pair(
        master: &dyn MasterPty,
        stopped: Arc<AtomicBool>,
    ) -> io::Result<(Self, Self)> {
        let fd = master
            .as_raw_fd()
            .ok_or_else(|| io::Error::other("Unix PTY has no master descriptor"))?;
        // SAFETY: master owns fd throughout this duplication. Each File
        // below owns its duplicate, including while shutdown drops master.
        let file = File::from(unsafe { BorrowedFd::borrow_raw(fd) }.try_clone_to_owned()?);
        // SAFETY: fd is live; these fcntl operations take integer arguments.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags == -1 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } == -1
        {
            return Err(io::Error::last_os_error());
        }
        Ok((
            Self {
                file: file.try_clone()?,
                stopped: Arc::clone(&stopped),
            },
            Self { file, stopped },
        ))
    }

    fn check_running(&self) -> io::Result<()> {
        if self.stopped.load(Ordering::Acquire) {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "PTY stopped"))
        } else {
            Ok(())
        }
    }

    #[allow(unsafe_code)]
    fn wait(&self, events: libc::c_short) -> io::Result<()> {
        let mut descriptor = libc::pollfd {
            fd: self.file.as_raw_fd(),
            events,
            revents: 0,
        };
        loop {
            self.check_running()?;
            // SAFETY: descriptor names our owned File and remains writable
            // for this one-element poll. The timeout bounds shutdown delay.
            match unsafe { libc::poll(&raw mut descriptor, 1, 50) } {
                -1 => {
                    let error = io::Error::last_os_error();
                    if error.kind() != io::ErrorKind::Interrupted {
                        return Err(error);
                    }
                }
                0 => {}
                _ => return Ok(()),
            }
        }
    }
}

impl Read for PtyIo {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        loop {
            self.check_running()?;
            match self.file.read(bytes) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    self.wait(libc::POLLIN)?;
                }
                result => return result,
            }
        }
    }
}

impl Write for PtyIo {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        loop {
            self.check_running()?;
            match self.file.write(bytes) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    self.wait(libc::POLLOUT)?;
                }
                result => return result,
            }
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}
