//! Narrow wrappers around Windows system-directory discovery.

#![allow(
    unsafe_code,
    reason = "GetSystemDirectoryW is the authoritative source for system executables"
)]

use std::ffi::OsString;
use std::io;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;

use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;

pub(crate) fn wsl_executable() -> io::Result<OsString> {
    let mut buffer = vec![0_u16; 260];
    loop {
        let capacity = u32::try_from(buffer.len()).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "Windows system-directory buffer exceeds the Win32 limit",
            )
        })?;
        // SAFETY: `buffer` is writable for the length passed to Win32. The API
        // returns the required size when the buffer is too small and does not
        // retain the pointer.
        let length = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), capacity) };
        if length == 0 {
            return Err(io::Error::last_os_error());
        }
        let length = length as usize;
        if length < buffer.len() {
            let mut path = PathBuf::from(OsString::from_wide(&buffer[..length]));
            path.push("wsl.exe");
            return Ok(path.into_os_string());
        }
        buffer.resize(length + 1, 0);
    }
}
