#[cfg(windows)]
mod platform {
    #![allow(unsafe_code)]

    use std::mem::size_of;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::os::windows::process::CommandExt;
    use std::process::{Child, Command};
    use std::ptr;

    use windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE;
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
    };
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectExtendedLimitInformation,
        SetInformationJobObject, TerminateJobObject,
    };
    use windows_sys::Win32::System::Threading::{
        CREATE_SUSPENDED, OpenThread, ResumeThread, THREAD_SUSPEND_RESUME,
    };

    pub fn prepare(command: &mut Command) {
        command.creation_flags(CREATE_SUSPENDED);
    }

    pub struct CommandContainment {
        job: Option<OwnedHandle>,
    }

    impl CommandContainment {
        pub fn attach(child: &mut Child) -> std::io::Result<Self> {
            // SAFETY: Null pointers request an unnamed job with default
            // security attributes. The returned owned handle is checked.
            let raw = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
            if raw.is_null() {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: `raw` is a fresh, non-null owned handle.
            let job = unsafe { OwnedHandle::from_raw_handle(raw) };
            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let byte_count = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
                .expect("Job Object limits fit in u32");
            // SAFETY: The handle is live and the pointer/size pair describes
            // `limits` for the duration of this call.
            if unsafe {
                SetInformationJobObject(
                    job.as_raw_handle(),
                    JobObjectExtendedLimitInformation,
                    ptr::from_ref(&limits).cast(),
                    byte_count,
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error());
            }
            // SAFETY: Both handles are live; assignment transfers neither.
            if unsafe { AssignProcessToJobObject(job.as_raw_handle(), child.as_raw_handle()) } == 0
            {
                return Err(std::io::Error::last_os_error());
            }
            resume_suspended_child(child)?;
            Ok(Self { job: Some(job) })
        }

        pub fn terminate(&mut self) {
            let Some(job) = self.job.take() else {
                return;
            };
            // SAFETY: `job` remains live. Failure is best-effort because the
            // job may already contain no live processes.
            let _ignored = unsafe { TerminateJobObject(job.as_raw_handle(), 1) };
        }
    }

    fn resume_suspended_child(child: &Child) -> std::io::Result<()> {
        // `std::process::Command` does not expose the primary thread handle.
        // The child has not run yet, so its only thread is safely discoverable
        // after the process has been assigned to the Job Object.
        // SAFETY: The snapshot handle is checked before it becomes owned.
        let raw_snapshot = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) };
        if raw_snapshot == INVALID_HANDLE_VALUE {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: `raw_snapshot` is a fresh, valid owned handle.
        let snapshot = unsafe { OwnedHandle::from_raw_handle(raw_snapshot) };
        let mut entry = THREADENTRY32 {
            dwSize: u32::try_from(size_of::<THREADENTRY32>())
                .expect("thread entry size fits in u32"),
            ..THREADENTRY32::default()
        };
        // SAFETY: `snapshot` is live and `entry` has the required size.
        if unsafe { Thread32First(snapshot.as_raw_handle(), &raw mut entry) } == 0 {
            return Err(std::io::Error::last_os_error());
        }

        loop {
            if entry.th32OwnerProcessID == child.id() {
                // SAFETY: The ID came from the system snapshot. The returned
                // handle is checked and receives only suspend/resume access.
                let raw_thread =
                    unsafe { OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID) };
                if raw_thread.is_null() {
                    return Err(std::io::Error::last_os_error());
                }
                // SAFETY: `raw_thread` is a fresh, non-null owned handle.
                let thread = unsafe { OwnedHandle::from_raw_handle(raw_thread) };
                // SAFETY: The handle grants suspend/resume access and remains
                // live for this call.
                let previous_suspend_count = unsafe { ResumeThread(thread.as_raw_handle()) };
                if previous_suspend_count == u32::MAX {
                    return Err(std::io::Error::last_os_error());
                }
                if previous_suspend_count != 1 {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        format!(
                            "host command had unexpected suspend count {previous_suspend_count}"
                        ),
                    ));
                }
                return Ok(());
            }
            // SAFETY: `snapshot` and `entry` remain valid. A zero result means
            // there are no more entries; the target thread was not found.
            if unsafe { Thread32Next(snapshot.as_raw_handle(), &raw mut entry) } == 0 {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "suspended child thread was not found",
                ));
            }
        }
    }

    #[cfg(test)]
    mod tests {
        use std::process::Stdio;
        use std::thread;
        use std::time::{Duration, SystemTime};

        use super::*;

        const MARKER_ENV: &str = "GHOSTHUB_SUSPENDED_CHILD_MARKER";

        #[test]
        fn prepared_child_executes_only_after_job_attachment() {
            let marker = std::env::temp_dir().join(format!(
                "ghosthub-suspended-child-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(SystemTime::UNIX_EPOCH)
                    .expect("system clock after Unix epoch")
                    .as_nanos()
            ));
            let mut command =
                Command::new(std::env::current_exe().expect("current test executable"));
            command
                .args([
                    "--ignored",
                    "--exact",
                    "command_process::platform::tests::suspended_child_helper",
                ])
                .env(MARKER_ENV, &marker)
                .stdout(Stdio::null())
                .stderr(Stdio::null());
            prepare(&mut command);
            let mut child = command.spawn().expect("spawn suspended child");

            assert!(!marker.exists(), "suspended child executed user code");

            let containment = CommandContainment::attach(&mut child).unwrap_or_else(|error| {
                let _ignored = child.kill();
                panic!("attach suspended child to Job Object: {error}")
            });
            let status = child.wait().expect("wait for resumed child");
            assert!(status.success());
            assert!(marker.exists(), "resumed child did not execute user code");

            drop(containment);
            std::fs::remove_file(marker).expect("remove suspended-child marker");
        }

        #[test]
        fn unsuspended_child_is_rejected_before_user_work_can_escape() {
            let mut child = Command::new(std::env::current_exe().expect("current test executable"))
                .args([
                    "--ignored",
                    "--exact",
                    "command_process::platform::tests::unsuspended_child_helper",
                ])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawn unsuspended child");

            let error = match CommandContainment::attach(&mut child) {
                Ok(mut containment) => {
                    containment.terminate();
                    let _ignored = child.wait();
                    panic!("unsuspended child was accepted")
                }
                Err(error) => error,
            };
            let _ignored = child.wait();

            assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
            assert!(error.to_string().contains("unexpected suspend count 0"));
        }

        #[test]
        #[ignore = "subprocess helper selected explicitly by the containment test"]
        fn suspended_child_helper() {
            let marker = std::env::var_os(MARKER_ENV).expect("marker path is configured");
            std::fs::write(marker, b"executed").expect("write execution marker");
        }

        #[test]
        #[ignore = "subprocess helper selected explicitly by the containment test"]
        fn unsuspended_child_helper() {
            loop {
                thread::sleep(Duration::from_secs(1));
            }
        }
    }
}

#[cfg(unix)]
mod platform {
    #![allow(unsafe_code)]

    use std::os::unix::process::CommandExt;
    use std::process::{Child, Command};

    pub fn prepare(command: &mut Command) {
        command.process_group(0);
    }

    pub struct CommandContainment {
        process_group: Option<i32>,
    }

    impl CommandContainment {
        pub fn attach(child: &mut Child) -> std::io::Result<Self> {
            let process_group = i32::try_from(child.id())
                .map_err(|_| std::io::Error::other("child process ID exceeds i32"))?;
            Ok(Self {
                process_group: Some(process_group),
            })
        }

        pub fn terminate(&mut self) {
            let Some(process_group) = self.process_group.take() else {
                return;
            };
            // SAFETY: A negative PID addresses only the process group created
            // for this command. Signal failure is harmless when it is empty.
            let _ignored = unsafe { libc::kill(-process_group, libc::SIGKILL) };
        }
    }
}

pub use platform::{CommandContainment, prepare};
