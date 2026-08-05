#[cfg(windows)]
mod platform {
    #![allow(unsafe_code)]

    use std::fmt;
    use std::mem::size_of;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use std::ptr;

    use portable_pty::Child;
    use windows_sys::Win32::Foundation::CloseHandle;
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, IsProcessInJob,
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JobObjectExtendedLimitInformation, SetInformationJobObject,
    };

    #[derive(Debug)]
    pub struct JobError(std::io::Error);

    impl fmt::Display for JobError {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(formatter, "relay Job Object: {}", self.0)
        }
    }

    impl std::error::Error for JobError {}

    pub struct RelayJob {
        handle: OwnedHandle,
    }

    impl RelayJob {
        pub fn new() -> Result<Self, JobError> {
            // SAFETY: Both pointers are null by design, requesting an unnamed
            // job with default security attributes. The returned owned handle
            // is checked before taking ownership.
            let raw = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
            if raw.is_null() {
                return Err(last_error());
            }
            // SAFETY: `raw` is a fresh, non-null owned handle returned above.
            let handle = unsafe { OwnedHandle::from_raw_handle(raw) };
            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            let byte_count = u32::try_from(size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())
                .expect("Job Object limit structure size fits u32");
            // SAFETY: The handle is valid, and the pointer/size pair describes
            // a live extended-limit structure for the duration of the call.
            let configured = unsafe {
                SetInformationJobObject(
                    handle.as_raw_handle(),
                    JobObjectExtendedLimitInformation,
                    ptr::from_ref(&limits).cast(),
                    byte_count,
                )
            };
            if configured == 0 {
                return Err(last_error());
            }
            Ok(Self { handle })
        }

        pub fn assign_and_verify(&self, child: &dyn Child) -> Result<(), JobError> {
            let process = child
                .as_raw_handle()
                .ok_or_else(|| JobError(std::io::Error::other("child has no process handle")))?;
            // SAFETY: Both handles are live for this call. Assignment neither
            // transfers nor closes either handle.
            if unsafe { AssignProcessToJobObject(self.handle.as_raw_handle(), process) } == 0 {
                return Err(last_error());
            }

            let mut contained = 0;
            // SAFETY: Both handles are live and `contained` is a valid writable
            // BOOL for the duration of this call.
            let queried = unsafe {
                IsProcessInJob(
                    process,
                    self.handle.as_raw_handle(),
                    ptr::from_mut(&mut contained),
                )
            };
            if queried == 0 {
                return Err(last_error());
            }
            if contained == 0 {
                return Err(JobError(std::io::Error::other(
                    "relay was not assigned to its kill-on-close job",
                )));
            }
            Ok(())
        }
    }

    fn last_error() -> JobError {
        JobError(std::io::Error::last_os_error())
    }

    // Assert that the selected windows-sys feature set links CloseHandle;
    // OwnedHandle performs the actual close.
    const _: unsafe extern "system" fn(*mut core::ffi::c_void) -> i32 = CloseHandle;
}

#[cfg(not(windows))]
mod platform {
    use std::fmt;

    use portable_pty::Child;

    #[derive(Debug)]
    pub struct JobError;

    impl fmt::Display for JobError {
        fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("relay jobs are unavailable on this platform")
        }
    }

    impl std::error::Error for JobError {}

    pub struct RelayJob;

    impl RelayJob {
        pub fn new() -> Result<Self, JobError> {
            Ok(Self)
        }

        pub fn assign_and_verify(&self, _child: &dyn Child) -> Result<(), JobError> {
            Ok(())
        }
    }
}

pub use platform::RelayJob;
