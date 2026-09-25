use std::env;
use std::path::{Component, Path, PathBuf};

use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum EndpointError {
    #[error("GRAPHCODE_DAEMON_PIPE must start with \\\\.\\pipe\\")]
    InvalidPipeOverride,
    #[error("the current user's home directory is unavailable")]
    HomeDirectoryUnavailable,
    #[error("the GraphCode support directory is unavailable: {0}")]
    SupportDirectoryUnavailable(String),
    #[error("the GraphCode rendezvous secret is missing or invalid: {0}")]
    RendezvousSecretInvalid(String),
    #[error("the current Windows user SID could not be read: {0}")]
    SidUnavailable(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonEndpoint {
    #[cfg(windows)]
    NamedPipe(String),
    #[cfg(unix)]
    UnixSocket(PathBuf),
}

impl DaemonEndpoint {
    pub fn display_name(&self) -> String {
        match self {
            #[cfg(windows)]
            Self::NamedPipe(name) => name.clone(),
            #[cfg(unix)]
            Self::UnixSocket(path) => path.display().to_string(),
        }
    }
}

pub fn discover() -> Result<DaemonEndpoint, EndpointError> {
    #[cfg(windows)]
    {
        discover_windows()
    }
    #[cfg(unix)]
    {
        discover_unix()
    }
}

fn home_directory() -> Result<PathBuf, EndpointError> {
    env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .ok_or(EndpointError::HomeDirectoryUnavailable)
}

fn configured_support_directory() -> Result<PathBuf, EndpointError> {
    let home = home_directory()?;
    let configured = env::var_os("GRAPHCODE_SUPPORT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".graphcode"));
    Ok(if configured.is_absolute() {
        configured
    } else {
        home.join(configured)
    })
}

fn normalize_lexically(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

#[cfg(windows)]
fn swift_standardized_support_identity(path: &Path) -> String {
    normalize_lexically(path)
        .to_string_lossy()
        .replace('\\', "/")
        .to_lowercase()
}

#[cfg(windows)]
fn windows_pipe_name(sid: &str, support_hash: &str, rendezvous_hash: &str) -> String {
    format!(
        r"\\.\pipe\graphcode-{sid}-{}-{}",
        &support_hash[..24],
        &rendezvous_hash[..24]
    )
}

#[cfg(windows)]
fn discover_windows() -> Result<DaemonEndpoint, EndpointError> {
    if let Some(value) =
        env::var_os("GRAPHCODE_DAEMON_PIPE").or_else(|| env::var_os("GRAPHCODE_SOCKET"))
    {
        let pipe = value.to_string_lossy().into_owned();
        if !pipe.starts_with(r"\\.\pipe\") {
            return Err(EndpointError::InvalidPipeOverride);
        }
        return Ok(DaemonEndpoint::NamedPipe(pipe));
    }

    let support = configured_support_directory()?;
    if !support.is_dir() {
        return Err(EndpointError::SupportDirectoryUnavailable(
            support.display().to_string(),
        ));
    }
    let support_identity = swift_standardized_support_identity(&support);
    let support_hash = sha256_hex(support_identity.as_bytes());
    let secret_path = support.join(".graphcode-rendezvous.secret");
    let secret = std::fs::read(&secret_path).map_err(|error| {
        EndpointError::RendezvousSecretInvalid(format!("{} ({error})", secret_path.display()))
    })?;
    if secret.len() != 32 || secret.iter().all(|byte| *byte == 0) {
        return Err(EndpointError::RendezvousSecretInvalid(
            secret_path.display().to_string(),
        ));
    }
    let rendezvous_hash = sha256_hex(&secret);
    let sid = current_windows_sid()?;
    Ok(DaemonEndpoint::NamedPipe(windows_pipe_name(
        &sid,
        &support_hash,
        &rendezvous_hash,
    )))
}

#[cfg(windows)]
fn current_windows_sid() -> Result<String, EndpointError> {
    use std::ffi::c_void;
    use std::ptr::{null_mut, NonNull};
    use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, HLOCAL};
    use windows_sys::Win32::Security::Authorization::ConvertSidToStringSidW;
    use windows_sys::Win32::Security::{GetTokenInformation, TokenUser, TOKEN_QUERY, TOKEN_USER};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

    struct HandleGuard(HANDLE);
    impl Drop for HandleGuard {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    struct LocalGuard(NonNull<u16>);
    impl Drop for LocalGuard {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0.as_ptr() as HLOCAL);
            }
        }
    }

    unsafe {
        let mut token: HANDLE = null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(EndpointError::SidUnavailable(
                std::io::Error::last_os_error().to_string(),
            ));
        }
        let _token_guard = HandleGuard(token);

        let mut required = 0u32;
        GetTokenInformation(token, TokenUser, null_mut(), 0, &mut required);
        if required == 0 {
            return Err(EndpointError::SidUnavailable(
                std::io::Error::last_os_error().to_string(),
            ));
        }
        let mut buffer = vec![0u8; required as usize];
        if GetTokenInformation(
            token,
            TokenUser,
            buffer.as_mut_ptr().cast::<c_void>(),
            required,
            &mut required,
        ) == 0
        {
            return Err(EndpointError::SidUnavailable(
                std::io::Error::last_os_error().to_string(),
            ));
        }
        let token_user = &*(buffer.as_ptr().cast::<TOKEN_USER>());
        let mut sid_text = null_mut();
        if ConvertSidToStringSidW(token_user.User.Sid, &mut sid_text) == 0 {
            return Err(EndpointError::SidUnavailable(
                std::io::Error::last_os_error().to_string(),
            ));
        }
        let sid_guard = LocalGuard(NonNull::new(sid_text).ok_or_else(|| {
            EndpointError::SidUnavailable("ConvertSidToStringSidW returned null".into())
        })?);
        let length = (0..)
            .take_while(|offset| *sid_guard.0.as_ptr().add(*offset) != 0)
            .count();
        Ok(String::from_utf16_lossy(std::slice::from_raw_parts(
            sid_guard.0.as_ptr(),
            length,
        )))
    }
}

#[cfg(unix)]
fn discover_unix() -> Result<DaemonEndpoint, EndpointError> {
    if let Some(value) = env::var_os("GRAPHCODE_SOCKET") {
        return Ok(DaemonEndpoint::UnixSocket(PathBuf::from(value)));
    }
    Ok(DaemonEndpoint::UnixSocket(
        configured_support_directory()?.join("graphcoded.sock"),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lexical_normalization_removes_current_and_parent_components() {
        let path = Path::new(r"C:\Users\graphcode\workspace\..\.\.graphcode");
        assert_eq!(
            normalize_lexically(path),
            PathBuf::from(r"C:\Users\graphcode\.graphcode")
        );
    }

    #[test]
    fn sha256_matches_the_endpoint_contract() {
        assert_eq!(
            sha256_hex(b"graphcode"),
            "8f19c93e35d40aea60fc26b3f078e4d824ccc9254ee066bfb7fd50474805b8cf"
        );
    }

    #[cfg(windows)]
    #[test]
    fn support_identity_matches_swift_standardized_file_url_on_windows() {
        let identity = swift_standardized_support_identity(Path::new(r"C:\Users\rsim\.graphcode"));

        assert_eq!(identity, "c:/users/rsim/.graphcode");
        assert_eq!(
            &sha256_hex(identity.as_bytes())[..24],
            "7ad9235de28c7263ad224621"
        );
        assert_ne!(
            &sha256_hex(r"c:\users\rsim\.graphcode".as_bytes())[..24],
            "7ad9235de28c7263ad224621"
        );
    }

    #[cfg(windows)]
    #[test]
    fn measured_windows_endpoint_matches_graphcodekit_identity() {
        assert_eq!(
            windows_pipe_name(
                "S-1-12-1-26826728-1292762066-611294080-2095150415",
                "7ad9235de28c7263ad2246210000000000000000000000000000000000000000",
                "4b0610f0cafaa34bb20004830000000000000000000000000000000000000000",
            ),
            r"\\.\pipe\graphcode-S-1-12-1-26826728-1292762066-611294080-2095150415-7ad9235de28c7263ad224621-4b0610f0cafaa34bb2000483"
        );
    }
}
