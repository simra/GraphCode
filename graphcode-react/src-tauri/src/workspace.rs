use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

use crate::endpoint;

const DIRECTORY_PREFIX: &str = ".graphcode-";
const LOCK_FILE: &str = ".graphcode-react.lock";
const LEGACY_LOCK_FILE: &str = "app.pid";
const DELETION_LOCK_PREFIX: &str = ".graphcode-deleting-";
const RENDEZVOUS_FILE: &str = ".graphcode-rendezvous.secret";
const RECOVERY_DIRECTORY: &str = ".graphcode_recovery";
const ZMX_NAMESPACE_DIRECTORY: &str = ".graphcode-zmx";
const ZMX_NAMESPACE_MARKER: &str = ".graphcode-zmx-namespace-v1";

#[derive(Debug, Error)]
pub enum WorkspaceError {
    #[error("the current user's home directory is unavailable")]
    HomeUnavailable,
    #[error("failed to access GraphCode workspaces: {0}")]
    Io(String),
    #[error("give the workspace a name using letters and numbers")]
    InvalidName,
    #[error("a workspace named {0} already exists")]
    AlreadyExists(String),
    #[error("workspace not found")]
    NotFound,
    #[error("the default workspace cannot be renamed")]
    DefaultWorkspace,
    #[error("the current workspace cannot be renamed from its own window")]
    CurrentWorkspace,
    #[error("the default workspace cannot be deleted")]
    DefaultWorkspaceDeletion,
    #[error("the current workspace cannot be deleted from its own window")]
    CurrentWorkspaceDeletion,
    #[error("that workspace is open in another GraphCode window")]
    OpenWorkspace,
    #[error("workspace deletion refused because ownership could not be proven: {0}")]
    OwnershipUncertain(String),
    #[error("workspace deletion refused because the path is not canonical: {0}")]
    PathUncertain(String),
    #[error("workspace deletion refused because a reparse point was found at {0}")]
    ReparsePoint(String),
    #[error("workspace deletion refused because process ownership is uncertain: {0}")]
    ProcessOwnershipUncertain(String),
    #[error("workspace deletion refused because required filesystem access was denied: {0}")]
    PermissionDenied(String),
    #[error("workspace teardown did not complete: {0}")]
    TeardownIncomplete(String),
    #[error("workspace recovery could not be guaranteed: {0}")]
    RecoveryUncertain(String),
    #[error("workspace mutation synchronization failed: {0}")]
    Synchronization(String),
    #[error("workspace confirmation no longer matches the canonical path (expected {expected}, found {actual})")]
    ConfirmationMismatch { expected: String, actual: String },
    #[error("workspace confirmation expired because the directory identity changed")]
    ConfirmationIdentityMismatch,
    #[error("GraphCode helpers are unavailable at {0}")]
    HelpersUnavailable(String),
    #[error("failed to start the workspace daemon: {0}")]
    DaemonStart(String),
    #[error("the workspace daemon did not initialize within five seconds")]
    DaemonTimeout,
    #[error("failed to open the workspace window: {0}")]
    AppStart(String),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSummary {
    pub id: String,
    pub name: String,
    pub path: String,
    pub is_default: bool,
    pub is_current: bool,
    pub is_open: bool,
    pub projects: usize,
    pub loops: usize,
    pub terminal_sessions: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceDeletionPlan {
    pub id: String,
    pub name: String,
    pub canonical_path: String,
    pub recovery_path: String,
    pub identity_token: String,
    pub projects: usize,
    pub loops: usize,
    pub terminal_sessions: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceDeletionResult {
    pub committed: bool,
    pub recovery_path: String,
    pub cleanup_warning: Option<String>,
}

#[cfg(windows)]
struct WorkspaceMutationGuard {
    handle: windows_sys::Win32::Foundation::HANDLE,
}

#[cfg(windows)]
impl WorkspaceMutationGuard {
    fn acquire(home: &Path) -> Result<Self, WorkspaceError> {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Foundation::{
            CloseHandle, GetLastError, WAIT_ABANDONED, WAIT_OBJECT_0, WAIT_TIMEOUT,
        };
        use windows_sys::Win32::System::Threading::{CreateMutexW, WaitForSingleObject};

        let sid = endpoint::current_windows_sid()
            .map_err(|error| WorkspaceError::Synchronization(error.to_string()))?;
        let home = canonical_existing(home)?;
        let identity = hex::encode(Sha256::digest(
            home.to_string_lossy().to_lowercase().as_bytes(),
        ));
        let name = format!(r"Local\GraphCode.Workspaces.{sid}.{}", &identity[..32]);
        let wide: Vec<u16> = std::ffi::OsStr::new(&name)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        unsafe {
            let handle = CreateMutexW(std::ptr::null(), 0, wide.as_ptr());
            if handle.is_null() {
                let error = GetLastError();
                if error == windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED {
                    return Err(WorkspaceError::PermissionDenied(
                        "could not create the workspace synchronization mutex".into(),
                    ));
                }
                return Err(WorkspaceError::Synchronization(format!(
                    "could not create workspace mutex (Windows error {})",
                    error
                )));
            }
            match WaitForSingleObject(handle, 30_000) {
                WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(Self { handle }),
                WAIT_TIMEOUT => {
                    CloseHandle(handle);
                    Err(WorkspaceError::Synchronization(
                        "timed out waiting for another workspace operation".into(),
                    ))
                }
                result => {
                    CloseHandle(handle);
                    Err(WorkspaceError::Synchronization(format!(
                        "workspace mutex wait failed with status {result}"
                    )))
                }
            }
        }
    }
}

#[cfg(windows)]
impl Drop for WorkspaceMutationGuard {
    fn drop(&mut self) {
        use windows_sys::Win32::Foundation::CloseHandle;
        use windows_sys::Win32::System::Threading::ReleaseMutex;
        unsafe {
            ReleaseMutex(self.handle);
            CloseHandle(self.handle);
        }
    }
}

#[cfg(not(windows))]
struct WorkspaceMutationGuard;

#[cfg(not(windows))]
impl WorkspaceMutationGuard {
    fn acquire(_home: &Path) -> Result<Self, WorkspaceError> {
        Ok(Self)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DirectoryIdentity {
    volume_serial: u64,
    file_id: [u8; 16],
}

#[cfg(windows)]
struct StableDirectory {
    handle: windows_sys::Win32::Foundation::HANDLE,
    identity: DirectoryIdentity,
}

#[cfg(windows)]
impl StableDirectory {
    fn open(path: &Path) -> Result<Self, WorkspaceError> {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Foundation::{GetLastError, INVALID_HANDLE_VALUE};
        use windows_sys::Win32::Storage::FileSystem::{
            CreateFileW, DELETE, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
            FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE,
            OPEN_EXISTING,
        };

        let wide: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        unsafe {
            let handle = CreateFileW(
                wide.as_ptr(),
                FILE_READ_ATTRIBUTES | DELETE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                std::ptr::null_mut(),
            );
            if handle == INVALID_HANDLE_VALUE {
                let error = GetLastError();
                if error == windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED {
                    return Err(WorkspaceError::PermissionDenied(format!(
                        "could not hold directory {}",
                        path.display()
                    )));
                }
                return Err(WorkspaceError::PathUncertain(format!(
                    "could not hold directory {} (Windows error {})",
                    path.display(),
                    error
                )));
            }
            let identity = match Self::identity_for_handle(handle) {
                Ok(identity) => identity,
                Err(error) => {
                    windows_sys::Win32::Foundation::CloseHandle(handle);
                    return Err(error);
                }
            };
            Ok(Self { handle, identity })
        }
    }

    fn identity_for_handle(
        handle: windows_sys::Win32::Foundation::HANDLE,
    ) -> Result<DirectoryIdentity, WorkspaceError> {
        use windows_sys::Win32::Foundation::GetLastError;
        use windows_sys::Win32::Storage::FileSystem::{
            FileIdInfo, GetFileInformationByHandleEx, FILE_ID_INFO,
        };
        let mut info = FILE_ID_INFO::default();
        unsafe {
            if GetFileInformationByHandleEx(
                handle,
                FileIdInfo,
                (&mut info as *mut FILE_ID_INFO).cast(),
                std::mem::size_of::<FILE_ID_INFO>() as u32,
            ) == 0
            {
                let error = GetLastError();
                if error == windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED {
                    return Err(WorkspaceError::PermissionDenied(
                        "could not read stable directory identity".into(),
                    ));
                }
                return Err(WorkspaceError::PathUncertain(format!(
                    "could not read stable directory identity (Windows error {})",
                    error
                )));
            }
        }
        Ok(DirectoryIdentity {
            volume_serial: info.VolumeSerialNumber,
            file_id: info.FileId.Identifier,
        })
    }

    fn verify_path(&self, path: &Path) -> Result<(), WorkspaceError> {
        let current = Self::open(path)?;
        if current.identity != self.identity {
            return Err(WorkspaceError::PathUncertain(format!(
                "{} was replaced while deletion was pending",
                path.display()
            )));
        }
        Ok(())
    }

    fn confirmation_token(&self) -> String {
        self.identity.confirmation_token()
    }

    fn rename_to(&self, destination: &Path) -> Result<(), WorkspaceError> {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Foundation::GetLastError;
        use windows_sys::Win32::Storage::FileSystem::{
            FileRenameInfo, SetFileInformationByHandle, FILE_RENAME_INFO,
        };

        let destination_text = destination.to_str().ok_or_else(|| {
            WorkspaceError::RecoveryUncertain(format!(
                "{} cannot be represented as a Windows recovery path",
                destination.display()
            ))
        })?;
        let destination_nt = if let Some(path) = destination_text.strip_prefix(r"\\") {
            format!(r"\??\UNC\{path}")
        } else {
            format!(r"\??\{destination_text}")
        };
        let destination_wide: Vec<u16> = std::ffi::OsStr::new(&destination_nt)
            .encode_wide()
            .collect();
        let file_name_offset = std::mem::offset_of!(FILE_RENAME_INFO, FileName);
        let file_name_bytes = destination_wide
            .len()
            .checked_mul(std::mem::size_of::<u16>())
            .ok_or_else(|| {
                WorkspaceError::RecoveryUncertain(
                    "the recovery destination is too long to encode safely".into(),
                )
            })?;
        let byte_length = std::mem::size_of::<FILE_RENAME_INFO>()
            .checked_add(file_name_bytes)
            .ok_or_else(|| {
                WorkspaceError::RecoveryUncertain("the recovery rename request is too large".into())
            })?;
        let word_length = byte_length.div_ceil(std::mem::size_of::<usize>());
        let mut storage = vec![0usize; word_length];
        let rename = storage.as_mut_ptr().cast::<FILE_RENAME_INFO>();
        unsafe {
            (*rename).Anonymous.ReplaceIfExists = false;
            (*rename).RootDirectory = std::ptr::null_mut();
            (*rename).FileNameLength = u32::try_from(file_name_bytes).map_err(|_| {
                WorkspaceError::RecoveryUncertain(
                    "the recovery destination is too long to encode safely".into(),
                )
            })?;
            std::ptr::copy_nonoverlapping(
                destination_wide.as_ptr(),
                storage
                    .as_mut_ptr()
                    .cast::<u8>()
                    .add(file_name_offset)
                    .cast::<u16>(),
                destination_wide.len(),
            );
            if SetFileInformationByHandle(
                self.handle,
                FileRenameInfo,
                rename.cast(),
                u32::try_from(byte_length).map_err(|_| {
                    WorkspaceError::RecoveryUncertain(
                        "the recovery rename request is too large".into(),
                    )
                })?,
            ) == 0
            {
                let error = GetLastError();
                if error == windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED {
                    return Err(WorkspaceError::PermissionDenied(format!(
                        "could not move the verified workspace handle to {}",
                        destination.display()
                    )));
                }
                return Err(WorkspaceError::RecoveryUncertain(format!(
                    "could not move the verified workspace handle to {} (Windows error {})",
                    destination.display(),
                    error
                )));
            }
        }
        Ok(())
    }
}

#[cfg(windows)]
impl Drop for StableDirectory {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.handle);
        }
    }
}

#[cfg(not(windows))]
struct StableDirectory {
    path: PathBuf,
    identity: DirectoryIdentity,
}

#[cfg(not(windows))]
impl StableDirectory {
    fn open(path: &Path) -> Result<Self, WorkspaceError> {
        Ok(Self {
            path: canonical_existing(path)?,
            identity: DirectoryIdentity {
                volume_serial: 0,
                file_id: [0; 16],
            },
        })
    }

    fn verify_path(&self, path: &Path) -> Result<(), WorkspaceError> {
        if same_path(&self.path, &canonical_existing(path)?) {
            Ok(())
        } else {
            Err(WorkspaceError::PathUncertain(format!(
                "{} was replaced while deletion was pending",
                path.display()
            )))
        }
    }

    fn confirmation_token(&self) -> String {
        self.identity.confirmation_token()
    }
}

impl DirectoryIdentity {
    fn confirmation_token(&self) -> String {
        let mut digest = Sha256::new();
        digest.update(b"graphcode-workspace-deletion-identity-v1\0");
        digest.update(self.volume_serial.to_le_bytes());
        digest.update(self.file_id);
        hex::encode(digest.finalize())
    }
}

pub struct WorkspaceGuard {
    path: PathBuf,
    pid: u32,
}

impl WorkspaceGuard {
    pub fn acquire() -> Result<Self, WorkspaceError> {
        let directory = endpoint::configured_support_directory()
            .map_err(|error| WorkspaceError::Io(error.to_string()))?;
        fs::create_dir_all(&directory).map_err(|error| WorkspaceError::Io(error.to_string()))?;
        ensure_not_deleting(&directory)?;
        let path = directory.join(LOCK_FILE);
        let pid = std::process::id();
        if let Ok(existing) = fs::read_to_string(&path) {
            if existing.trim().parse::<u32>().is_ok_and(process_is_running) {
                return Err(WorkspaceError::OpenWorkspace);
            }
            fs::remove_file(&path).map_err(|error| WorkspaceError::Io(error.to_string()))?;
        }
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .and_then(|mut file| {
                use std::io::Write;
                file.write_all(pid.to_string().as_bytes())
            })
            .map_err(|error| WorkspaceError::Io(error.to_string()))?;
        Ok(Self { path, pid })
    }
}

impl Drop for WorkspaceGuard {
    fn drop(&mut self) {
        if fs::read_to_string(&self.path)
            .ok()
            .and_then(|value| value.trim().parse::<u32>().ok())
            == Some(self.pid)
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

pub fn list() -> Result<Vec<WorkspaceSummary>, WorkspaceError> {
    list_from(&home_directory()?, &current_directory()?)
}

pub fn create(name: &str) -> Result<WorkspaceSummary, WorkspaceError> {
    let home = home_directory()?;
    let _synchronization = WorkspaceMutationGuard::acquire(&home)?;
    let slug = slug(name)?;
    let path = home.join(format!("{DIRECTORY_PREFIX}{slug}"));
    if path.exists() {
        return Err(WorkspaceError::AlreadyExists(slug));
    }
    fs::create_dir(&path).map_err(|error| WorkspaceError::Io(error.to_string()))?;
    if let Err(error) = install_helpers(&home, &path) {
        let _ = fs::remove_dir_all(&path);
        return Err(error);
    }
    initialize_zmx_namespace(&path)?;
    summarize(&path, &current_directory()?, &home)
}

pub fn rename(id: &str, name: &str) -> Result<WorkspaceSummary, WorkspaceError> {
    let home = home_directory()?;
    let _synchronization = WorkspaceMutationGuard::acquire(&home)?;
    let current = current_directory()?;
    let source = resolve_known(&home, id)?;
    if same_path(&source, &home.join(".graphcode")) {
        return Err(WorkspaceError::DefaultWorkspace);
    }
    if same_path(&source, &current) {
        return Err(WorkspaceError::CurrentWorkspace);
    }
    if workspace_is_open(&source) {
        return Err(WorkspaceError::OpenWorkspace);
    }
    ensure_zmx_namespace_for_open(&source)?;
    if !zmx_sessions(&source)?.is_empty() {
        return Err(WorkspaceError::OwnershipUncertain(
            "stop all workspace-scoped terminal sessions before renaming this workspace".into(),
        ));
    }
    let zmx_secret = zmx_namespace_secret(&source)?;
    write_zmx_namespace_marker(&source, &zmx_secret, false)?;
    let destination = home.join(format!("{DIRECTORY_PREFIX}{}", slug(name)?));
    if destination.exists() {
        return Err(WorkspaceError::AlreadyExists(
            destination
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .trim_start_matches(DIRECTORY_PREFIX)
                .to_string(),
        ));
    }
    stop_scheduled_daemon(&source)?;
    verify_no_owned_processes(&source)?;
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match fs::rename(&source, &destination) {
            Ok(()) => break,
            Err(error) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(50));
                if error.kind() == std::io::ErrorKind::NotFound {
                    return Err(WorkspaceError::Io(error.to_string()));
                }
            }
            Err(error) => return Err(WorkspaceError::Io(error.to_string())),
        }
    }
    write_zmx_namespace_marker(&destination, &zmx_secret, false)?;
    verify_zmx_namespace(&destination)?;
    summarize(&destination, &current, &home)
}

pub fn delete(
    id: &str,
    expected_path: &str,
    expected_recovery_path: &str,
    expected_identity_token: &str,
) -> Result<WorkspaceDeletionResult, WorkspaceError> {
    let home = home_directory()?;
    let _synchronization = WorkspaceMutationGuard::acquire(&home)?;
    delete_from(
        &home,
        &current_directory()?,
        id,
        expected_path,
        expected_recovery_path,
        expected_identity_token,
        zmx_sessions,
        move_to_recovery,
        DeletionLease::cleanup_after_commit,
    )
}

pub fn prepare_delete(id: &str) -> Result<WorkspaceDeletionPlan, WorkspaceError> {
    let home = home_directory()?;
    let _synchronization = WorkspaceMutationGuard::acquire(&home)?;
    let current = current_directory()?;
    let target = validate_deletion_target(&home, &current, id)?;
    let stable = StableDirectory::open(&target)?;
    inspect_workspace_locks(&target)?;
    preflight_process_ownership(&target)?;
    verify_zmx_namespace(&target)?;
    let sessions = zmx_sessions(&target)?;
    let contents = workspace_contents(&target);
    let recovery_path = recovery_destination(&home, &target)?;
    let name = target
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(|name| name.strip_prefix(DIRECTORY_PREFIX))
        .ok_or_else(|| WorkspaceError::OwnershipUncertain(target.display().to_string()))?
        .to_string();
    Ok(WorkspaceDeletionPlan {
        id: id.to_string(),
        name,
        canonical_path: target.display().to_string(),
        recovery_path: recovery_path.display().to_string(),
        identity_token: stable.confirmation_token(),
        projects: contents.projects,
        loops: contents.loops,
        terminal_sessions: sessions.len(),
    })
}

pub fn open(id: &str) -> Result<(), WorkspaceError> {
    let home = home_directory()?;
    let _synchronization = WorkspaceMutationGuard::acquire(&home)?;
    let target = resolve_known(&home, id)?;
    if same_path(&target, &current_directory()?) {
        return Ok(());
    }
    ensure_not_deleting(&target)?;
    install_helpers(&home, &target)?;
    ensure_zmx_namespace_for_open(&target)?;
    start_daemon(&target)?;

    let executable =
        std::env::current_exe().map_err(|error| WorkspaceError::AppStart(error.to_string()))?;
    let mut command = Command::new(executable);
    command
        .env("GRAPHCODE_SUPPORT_DIR", &target)
        .env("ZMX_DIR", zmx_namespace_directory(&target))
        .current_dir(&target)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    hide_console(&mut command);
    let child = command
        .spawn()
        .map_err(|error| WorkspaceError::AppStart(error.to_string()))?;
    wait_for_workspace_window(&target, child.id())?;
    Ok(())
}

fn list_from(home: &Path, current: &Path) -> Result<Vec<WorkspaceSummary>, WorkspaceError> {
    let mut paths = vec![home.join(".graphcode")];
    if let Ok(entries) = fs::read_dir(home) {
        let mut named: Vec<_> = entries
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|path| {
                path.is_dir()
                    && path
                        .file_name()
                        .is_some_and(|name| name.to_string_lossy().starts_with(DIRECTORY_PREFIX))
            })
            .collect();
        named.sort_by_key(|path| {
            fs::metadata(path)
                .and_then(|metadata| metadata.created())
                .ok()
        });
        paths.extend(named);
    }
    if !paths.iter().any(|path| same_path(path, current)) {
        paths.push(current.to_path_buf());
    }
    paths
        .iter()
        .map(|path| summarize(path, current, home))
        .collect()
}

fn summarize(path: &Path, current: &Path, home: &Path) -> Result<WorkspaceSummary, WorkspaceError> {
    let default = home.join(".graphcode");
    let is_default = same_path(path, &default);
    let name = if is_default {
        "Default".into()
    } else {
        let file_name = path.file_name().unwrap_or_default().to_string_lossy();
        file_name
            .strip_prefix(DIRECTORY_PREFIX)
            .unwrap_or(&file_name)
            .to_string()
    };
    let contents = workspace_contents(path);
    Ok(WorkspaceSummary {
        id: path.display().to_string(),
        name,
        path: path.display().to_string(),
        is_default,
        is_current: same_path(path, current),
        is_open: workspace_is_open(path),
        projects: contents.projects,
        loops: contents.loops,
        terminal_sessions: contents.session_names.len(),
    })
}

#[derive(Default)]
struct WorkspaceContents {
    projects: usize,
    loops: usize,
    session_names: Vec<String>,
}

fn workspace_contents(workspace: &Path) -> WorkspaceContents {
    let mut contents = WorkspaceContents::default();
    let mut surface_ids = std::collections::BTreeSet::new();
    collect_project_contents(workspace, &mut contents, &mut surface_ids);
    collect_layout_surfaces(workspace, &mut surface_ids);
    contents.session_names = surface_ids
        .into_iter()
        .map(|id| format!("graphcode-{}", id.to_uppercase()))
        .collect();
    contents
}

fn collect_project_contents(
    workspace: &Path,
    contents: &mut WorkspaceContents,
    surface_ids: &mut std::collections::BTreeSet<String>,
) {
    let Ok(entries) = fs::read_dir(workspace.join("projects")) else {
        return;
    };
    for entry in entries.filter_map(Result::ok).filter(|entry| {
        entry
            .path()
            .extension()
            .is_some_and(|extension| extension == "json")
    }) {
        let Some(graph) = fs::read(entry.path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        else {
            continue;
        };
        let Some(nodes) = graph.get("nodes").and_then(Value::as_array) else {
            continue;
        };
        contents.projects += 1;
        contents.loops += nodes.len();
        for node in nodes {
            if let Some(id) = node.get("id").and_then(Value::as_str) {
                surface_ids.insert(id.to_string());
            }
        }
    }
}

fn collect_layout_surfaces(workspace: &Path, surface_ids: &mut std::collections::BTreeSet<String>) {
    let Ok(entries) = fs::read_dir(workspace.join("terminal-layouts")) else {
        return;
    };
    for entry in entries.filter_map(Result::ok).filter(|entry| {
        entry
            .path()
            .extension()
            .is_some_and(|extension| extension == "json")
    }) {
        let Some(layout) = fs::read(entry.path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        else {
            continue;
        };
        let Some(tabs) = layout.get("tabs").and_then(Value::as_array) else {
            continue;
        };
        for surface in tabs
            .iter()
            .filter_map(|tab| tab.get("surfaces").and_then(Value::as_array))
            .flatten()
        {
            if let Some(id) = surface.get("id").and_then(Value::as_str) {
                surface_ids.insert(id.to_string());
            }
        }
    }
}

fn slug(name: &str) -> Result<String, WorkspaceError> {
    let mut output = String::new();
    let mut separator = false;
    for character in name.trim().chars() {
        if character.is_ascii_alphanumeric() {
            if separator && !output.is_empty() {
                output.push('-');
            }
            output.push(character.to_ascii_lowercase());
            separator = false;
        } else {
            separator = true;
        }
        if output.len() >= 32 {
            break;
        }
    }
    while output.ends_with('-') {
        output.pop();
    }
    output.truncate(32);
    while output.ends_with('-') {
        output.pop();
    }
    if output.is_empty() {
        Err(WorkspaceError::InvalidName)
    } else {
        Ok(output)
    }
}

fn home_directory() -> Result<PathBuf, WorkspaceError> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .ok_or(WorkspaceError::HomeUnavailable)
}

fn current_directory() -> Result<PathBuf, WorkspaceError> {
    endpoint::configured_support_directory().map_err(|error| WorkspaceError::Io(error.to_string()))
}

pub(crate) fn zmx_namespace_directory(workspace: &Path) -> PathBuf {
    workspace.join(ZMX_NAMESPACE_DIRECTORY)
}

pub(crate) fn configured_zmx_namespace() -> Result<Option<PathBuf>, WorkspaceError> {
    let workspace = current_directory()?;
    if !workspace.join(ZMX_NAMESPACE_MARKER).is_file() {
        return Err(WorkspaceError::OwnershipUncertain(format!(
            "workspace has no trusted zmx namespace marker at {}; reopen it after all legacy sessions have stopped before creating or attaching terminals",
            workspace.join(ZMX_NAMESPACE_MARKER).display()
        )));
    }
    verify_zmx_namespace(&workspace)?;
    Ok(Some(zmx_namespace_directory(&workspace)))
}

fn workspace_identity(workspace: &Path) -> String {
    hex::encode(Sha256::digest(
        workspace.to_string_lossy().to_lowercase().as_bytes(),
    ))
}

fn zmx_namespace_secret(workspace: &Path) -> Result<String, WorkspaceError> {
    let workspace = canonical_existing(workspace)?;
    let marker = workspace.join(ZMX_NAMESPACE_MARKER);
    let actual = fs::read_to_string(&marker).map_err(|error| {
        WorkspaceError::OwnershipUncertain(format!(
            "workspace has no trusted zmx namespace marker at {}: {error}; reopen it after all legacy sessions have stopped",
            marker.display()
        ))
    })?;
    let mut lines = actual.lines();
    let version = lines.next();
    let identity = lines.next();
    let secret = lines.next();
    if version != Some("v1")
        || identity != Some(workspace_identity(&workspace).as_str())
        || secret.is_none_or(|value| {
            value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit())
        })
        || lines.next().is_some()
    {
        return Err(WorkspaceError::OwnershipUncertain(format!(
            "zmx namespace marker {} does not match this workspace",
            marker.display()
        )));
    }
    Ok(secret.expect("validated above").to_ascii_lowercase())
}

fn write_zmx_namespace_marker(
    workspace: &Path,
    secret: &str,
    create_new: bool,
) -> Result<(), WorkspaceError> {
    use std::io::Write;

    let marker = workspace.join(ZMX_NAMESPACE_MARKER);
    let mut options = fs::OpenOptions::new();
    options.write(true);
    if create_new {
        options.create_new(true);
    } else {
        options.create(true).truncate(true);
    }
    let mut file = options.open(&marker).map_err(|error| {
        map_io_error(
            error,
            format!("could not write zmx namespace marker {}", marker.display()),
        )
    })?;
    file.write_all(format!("v1\n{}\n{secret}\n", workspace_identity(workspace)).as_bytes())
        .map_err(|error| {
            map_io_error(
                error,
                format!("could not write zmx namespace marker {}", marker.display()),
            )
        })
}

fn initialize_zmx_namespace(workspace: &Path) -> Result<(), WorkspaceError> {
    let workspace = canonical_existing(workspace)?;
    if workspace.join(ZMX_NAMESPACE_MARKER).exists() {
        verify_zmx_namespace(&workspace)?;
        return Ok(());
    }
    let namespace = zmx_namespace_directory(&workspace);
    fs::create_dir(&namespace).map_err(|error| {
        map_io_error(
            error,
            format!("could not create zmx namespace {}", namespace.display()),
        )
    })?;
    reject_reparse_points(&namespace)?;
    let secret = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    write_zmx_namespace_marker(&workspace, &secret, true)
}

fn verify_zmx_namespace(workspace: &Path) -> Result<PathBuf, WorkspaceError> {
    let workspace = canonical_existing(workspace)?;
    zmx_namespace_secret(&workspace)?;
    let namespace = zmx_namespace_directory(&workspace);
    reject_reparse_points(&namespace)?;
    let canonical_namespace = canonical_existing(&namespace)?;
    if !canonical_namespace
        .parent()
        .is_some_and(|parent| same_path(parent, &workspace))
    {
        return Err(WorkspaceError::OwnershipUncertain(format!(
            "{} is not owned by {}",
            canonical_namespace.display(),
            workspace.display()
        )));
    }
    Ok(canonical_namespace)
}

fn ensure_zmx_namespace_for_open(workspace: &Path) -> Result<(), WorkspaceError> {
    if workspace.join(ZMX_NAMESPACE_MARKER).is_file() {
        verify_zmx_namespace(workspace)?;
        return Ok(());
    }
    if !owned_processes(workspace, "zmx.exe")?.is_empty() {
        return Err(WorkspaceError::OwnershipUncertain(
            "legacy zmx processes are still running; stop them before reopening this workspace"
                .into(),
        ));
    }
    if !owned_processes(workspace, "graphcoded.exe")?.is_empty() {
        return Err(WorkspaceError::OwnershipUncertain(
            "a legacy workspace daemon is still running; stop it before reopening this workspace"
                .into(),
        ));
    }
    initialize_zmx_namespace(workspace)
}

fn wait_for_workspace_window(workspace: &Path, expected_pid: u32) -> Result<(), WorkspaceError> {
    let path = workspace.join(LOCK_FILE);
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if fs::read_to_string(&path)
            .ok()
            .and_then(|value| value.trim().parse::<u32>().ok())
            == Some(expected_pid)
            && matches!(inspect_pid(expected_pid), PidState::Running)
        {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(WorkspaceError::AppStart(format!(
        "workspace window {expected_pid} did not acquire {}",
        path.display()
    )))
}

fn resolve_known(home: &Path, id: &str) -> Result<PathBuf, WorkspaceError> {
    resolve_known_from(home, &current_directory()?, id)
}

fn resolve_known_from(home: &Path, current: &Path, id: &str) -> Result<PathBuf, WorkspaceError> {
    let requested = PathBuf::from(id);
    list_from(home, current)?
        .into_iter()
        .find(|workspace| same_path(Path::new(&workspace.path), &requested))
        .map(|workspace| PathBuf::from(workspace.path))
        .ok_or(WorkspaceError::NotFound)
}

fn delete_from<L, F, C>(
    home: &Path,
    current: &Path,
    id: &str,
    expected_path: &str,
    expected_recovery_path: &str,
    expected_identity_token: &str,
    list_sessions: L,
    recover: F,
    cleanup_lease: C,
) -> Result<WorkspaceDeletionResult, WorkspaceError>
where
    L: FnOnce(&Path) -> Result<Vec<String>, WorkspaceError>,
    F: FnOnce(&Path, &Path, &StableDirectory) -> Result<Option<String>, WorkspaceError>,
    C: FnOnce(DeletionLease) -> Option<String>,
{
    let target = validate_deletion_target(home, current, id)?;
    let confirmed = canonical_existing(Path::new(expected_path))?;
    if !same_path(&target, &confirmed) {
        return Err(WorkspaceError::ConfirmationMismatch {
            expected: expected_path.to_string(),
            actual: target.display().to_string(),
        });
    }
    let stable = StableDirectory::open(&target)?;
    let actual_identity_token = stable.confirmation_token();
    if actual_identity_token != expected_identity_token {
        return Err(WorkspaceError::ConfirmationIdentityMismatch);
    }
    let recovery = validate_recovery_destination(home, &target, expected_recovery_path)?;
    let sessions = list_sessions(&target)?;

    inspect_workspace_locks(&target)?;
    let zmx_processes = owned_processes(&target, "zmx.exe")?;
    let daemon_processes = owned_processes(&target, "graphcoded.exe")?;
    let lease = DeletionLease::acquire(&target)?;
    inspect_workspace_locks(&target)?;
    stable.verify_path(&target)?;

    stop_scheduled_daemon(&target)?;
    end_zmx_sessions(&target, &sessions)?;
    terminate_owned_processes(zmx_processes)?;
    terminate_owned_processes(daemon_processes)?;
    terminate_owned_processes(owned_processes(&target, "zmx.exe")?)?;
    terminate_owned_processes(owned_processes(&target, "graphcoded.exe")?)?;
    verify_no_owned_processes(&target)?;
    remove_owned_runtime_files(&target)?;
    inspect_workspace_locks(&target)?;
    verify_no_owned_processes(&target)?;
    stable.verify_path(&target)?;

    let recovery_warning = recover(&target, &recovery, &stable)?;
    let cleanup_warning = match (recovery_warning, cleanup_lease(lease)) {
        (Some(recovery), Some(cleanup)) => Some(format!("{recovery} {cleanup}")),
        (Some(warning), None) | (None, Some(warning)) => Some(warning),
        (None, None) => None,
    };
    Ok(WorkspaceDeletionResult {
        committed: true,
        recovery_path: recovery.display().to_string(),
        cleanup_warning,
    })
}

fn validate_deletion_target(
    home: &Path,
    current: &Path,
    id: &str,
) -> Result<PathBuf, WorkspaceError> {
    let source = resolve_known_from(home, current, id)?;
    reject_reparse_points(&source)?;
    let home = canonical_existing(home)?;
    let target = canonical_existing(&source)?;
    let current = canonical_existing(current)?;
    let default = canonical_existing(&home.join(".graphcode"))?;

    if same_path(&target, &default) {
        return Err(WorkspaceError::DefaultWorkspaceDeletion);
    }
    if same_path(&target, &current) {
        return Err(WorkspaceError::CurrentWorkspaceDeletion);
    }
    if !target
        .parent()
        .is_some_and(|parent| same_path(parent, &home))
    {
        return Err(WorkspaceError::OwnershipUncertain(format!(
            "{} is not a direct child of {}",
            target.display(),
            home.display()
        )));
    }
    let name = target
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| WorkspaceError::OwnershipUncertain(target.display().to_string()))?;
    if !name.starts_with(DIRECTORY_PREFIX) || name.len() == DIRECTORY_PREFIX.len() {
        return Err(WorkspaceError::OwnershipUncertain(format!(
            "{} does not have a named-workspace identity",
            target.display()
        )));
    }
    for helper in ["graphcoded.exe", "zmx.exe"] {
        let path = target.join("bin").join(helper);
        let metadata = fs::metadata(&path).map_err(|error| {
            map_io_error(
                error,
                format!(
                    "required GraphCode helper is unavailable at {}",
                    path.display()
                ),
            )
        })?;
        if !metadata.is_file() {
            return Err(WorkspaceError::OwnershipUncertain(format!(
                "{} is not a regular file",
                path.display()
            )));
        }
    }
    Ok(target)
}

fn canonical_existing(path: &Path) -> Result<PathBuf, WorkspaceError> {
    fs::canonicalize(path)
        .map(normalize_verbatim_path)
        .map_err(|error| map_io_error(error, format!("could not canonicalize {}", path.display())))
}

#[cfg(windows)]
fn normalize_verbatim_path(path: PathBuf) -> PathBuf {
    let value = path.to_string_lossy();
    if let Some(rest) = value.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{rest}"));
    }
    value
        .strip_prefix(r"\\?\")
        .map(PathBuf::from)
        .unwrap_or(path)
}

#[cfg(not(windows))]
fn normalize_verbatim_path(path: PathBuf) -> PathBuf {
    path
}

fn reject_reparse_points(root: &Path) -> Result<(), WorkspaceError> {
    let metadata = fs::symlink_metadata(root)
        .map_err(|error| map_io_error(error, format!("could not inspect {}", root.display())))?;
    if metadata_is_reparse_point(&metadata) {
        return Err(WorkspaceError::ReparsePoint(root.display().to_string()));
    }
    if !metadata.is_dir() {
        return Ok(());
    }
    let entries = fs::read_dir(root)
        .map_err(|error| map_io_error(error, format!("could not enumerate {}", root.display())))?;
    for entry in entries {
        let entry = entry.map_err(|error| {
            map_io_error(error, format!("could not enumerate {}", root.display()))
        })?;
        reject_reparse_points(&entry.path())?;
    }
    Ok(())
}

#[cfg(windows)]
fn metadata_is_reparse_point(metadata: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    use windows_sys::Win32::Storage::FileSystem::FILE_ATTRIBUTE_REPARSE_POINT;
    metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

#[cfg(not(windows))]
fn metadata_is_reparse_point(metadata: &fs::Metadata) -> bool {
    metadata.file_type().is_symlink()
}

fn map_io_error(error: io::Error, context: String) -> WorkspaceError {
    if error.kind() == io::ErrorKind::PermissionDenied {
        WorkspaceError::PermissionDenied(format!("{context}: {error}"))
    } else {
        WorkspaceError::PathUncertain(format!("{context}: {error}"))
    }
}

enum PidState {
    Running,
    Exited,
    Uncertain(String),
}

fn inspect_workspace_locks(workspace: &Path) -> Result<(), WorkspaceError> {
    for name in [LOCK_FILE, LEGACY_LOCK_FILE] {
        let path = workspace.join(name);
        let text = match fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(map_io_error(
                    error,
                    format!("could not read workspace lock {}", path.display()),
                ))
            }
        };
        let pid = text.trim().parse::<u32>().map_err(|_| {
            WorkspaceError::OwnershipUncertain(format!(
                "{} does not contain a valid process id",
                path.display()
            ))
        })?;
        match inspect_pid(pid) {
            PidState::Running => return Err(WorkspaceError::OpenWorkspace),
            PidState::Exited => {}
            PidState::Uncertain(reason) => {
                return Err(WorkspaceError::ProcessOwnershipUncertain(reason))
            }
        }
    }
    Ok(())
}

fn ensure_not_deleting(workspace: &Path) -> Result<(), WorkspaceError> {
    let path = deletion_lease_path(workspace)?;
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => {
            return Err(map_io_error(
                error,
                format!("could not read deletion lease {}", path.display()),
            ))
        }
    };
    let pid = text.trim().parse::<u32>().map_err(|_| {
        WorkspaceError::OwnershipUncertain(format!(
            "{} does not contain a valid process id",
            path.display()
        ))
    })?;
    match inspect_pid(pid) {
        PidState::Running => Err(WorkspaceError::TeardownIncomplete(
            "workspace deletion is already in progress".into(),
        )),
        PidState::Exited => {
            fs::remove_file(&path).map_err(|error| {
                map_io_error(
                    error,
                    format!("could not remove stale deletion lease {}", path.display()),
                )
            })?;
            Ok(())
        }
        PidState::Uncertain(reason) => Err(WorkspaceError::ProcessOwnershipUncertain(reason)),
    }
}

struct DeletionLease {
    path: PathBuf,
    pid: u32,
    armed: std::sync::atomic::AtomicBool,
}

impl DeletionLease {
    fn acquire(workspace: &Path) -> Result<Self, WorkspaceError> {
        let path = deletion_lease_path(workspace)?;
        let pid = std::process::id();
        loop {
            match std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(mut file) => {
                    use std::io::Write;
                    file.write_all(pid.to_string().as_bytes())
                        .map_err(|error| {
                            map_io_error(
                                error,
                                format!("could not write deletion lease {}", path.display()),
                            )
                        })?;
                    return Ok(Self {
                        path,
                        pid,
                        armed: std::sync::atomic::AtomicBool::new(true),
                    });
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    let recorded = fs::read_to_string(&path)
                        .map_err(|error| {
                            map_io_error(
                                error,
                                format!("could not read deletion lease {}", path.display()),
                            )
                        })?
                        .trim()
                        .parse::<u32>()
                        .map_err(|_| {
                            WorkspaceError::OwnershipUncertain(format!(
                                "{} does not contain a valid process id",
                                path.display()
                            ))
                        })?;
                    match inspect_pid(recorded) {
                        PidState::Running => {
                            return Err(WorkspaceError::TeardownIncomplete(
                                "another workspace deletion is already in progress".into(),
                            ))
                        }
                        PidState::Exited => {
                            fs::remove_file(&path).map_err(|error| {
                                map_io_error(
                                    error,
                                    format!(
                                        "could not remove stale deletion lease {}",
                                        path.display()
                                    ),
                                )
                            })?;
                        }
                        PidState::Uncertain(reason) => {
                            return Err(WorkspaceError::ProcessOwnershipUncertain(reason))
                        }
                    }
                }
                Err(error) => {
                    return Err(map_io_error(
                        error,
                        format!("could not acquire deletion lease {}", path.display()),
                    ))
                }
            }
        }
    }

    fn cleanup_after_commit(self) -> Option<String> {
        self.cleanup_after_commit_with(|path| fs::remove_file(path))
    }

    fn cleanup_after_commit_with<F>(self, remove: F) -> Option<String>
    where
        F: FnOnce(&Path) -> io::Result<()>,
    {
        self.armed
            .store(false, std::sync::atomic::Ordering::Release);
        remove(&self.path).err().map(|error| {
            format!(
                "workspace recovery committed, but deletion lease cleanup failed at {}: {error}",
                self.path.display()
            )
        })
    }
}

impl Drop for DeletionLease {
    fn drop(&mut self) {
        if self.armed.load(std::sync::atomic::Ordering::Acquire)
            && fs::read_to_string(&self.path)
                .ok()
                .and_then(|value| value.trim().parse::<u32>().ok())
                == Some(self.pid)
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn deletion_lease_path(workspace: &Path) -> Result<PathBuf, WorkspaceError> {
    let workspace = canonical_existing(workspace)?;
    let parent = workspace.parent().ok_or_else(|| {
        WorkspaceError::OwnershipUncertain(format!(
            "{} has no parent directory",
            workspace.display()
        ))
    })?;
    let identity = workspace.to_string_lossy().to_lowercase();
    let hash = hex::encode(Sha256::digest(identity.as_bytes()));
    Ok(parent.join(format!("{DELETION_LOCK_PREFIX}{}.lock", &hash[..24])))
}

fn zmx_sessions(workspace: &Path) -> Result<Vec<String>, WorkspaceError> {
    use std::io::Read;

    let namespace = verify_zmx_namespace(workspace)?;
    let zmx = workspace.join("bin").join("zmx.exe");
    let mut child = Command::new(&zmx)
        .args(["list", "--short"])
        .env("ZMX_DIR", namespace)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| {
            WorkspaceError::OwnershipUncertain(format!(
                "could not enumerate workspace-scoped zmx sessions: {error}"
            ))
        })?;
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(WorkspaceError::OwnershipUncertain(
                    "workspace-scoped zmx session enumeration timed out".into(),
                ));
            }
            Err(error) => {
                return Err(WorkspaceError::OwnershipUncertain(format!(
                    "could not verify workspace-scoped zmx sessions: {error}"
                )))
            }
        }
    };
    let mut stdout = String::new();
    let mut stderr = String::new();
    child
        .stdout
        .take()
        .expect("zmx stdout was piped")
        .read_to_string(&mut stdout)
        .map_err(|error| {
            WorkspaceError::OwnershipUncertain(format!(
                "could not read workspace-scoped zmx sessions: {error}"
            ))
        })?;
    child
        .stderr
        .take()
        .expect("zmx stderr was piped")
        .read_to_string(&mut stderr)
        .map_err(|error| {
            WorkspaceError::OwnershipUncertain(format!(
                "could not read workspace-scoped zmx diagnostics: {error}"
            ))
        })?;
    if !status.success() {
        return Err(WorkspaceError::OwnershipUncertain(format!(
            "workspace-scoped zmx session enumeration failed: {}",
            stderr.trim()
        )));
    }
    Ok(stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect())
}

fn end_zmx_sessions(workspace: &Path, session_names: &[String]) -> Result<(), WorkspaceError> {
    let namespace = verify_zmx_namespace(workspace)?;
    let zmx = workspace.join("bin").join("zmx.exe");
    for session_name in session_names {
        let mut child = Command::new(&zmx)
            .args(["kill", session_name, "--force"])
            .env("ZMX_DIR", &namespace)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| {
                WorkspaceError::TeardownIncomplete(format!(
                    "failed to stop zmx session {session_name}: {error}"
                ))
            })?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(25));
                }
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(WorkspaceError::TeardownIncomplete(format!(
                        "zmx session {session_name} did not stop within five seconds"
                    )));
                }
                Err(error) => {
                    return Err(WorkspaceError::TeardownIncomplete(format!(
                        "could not verify zmx session {session_name} teardown: {error}"
                    )))
                }
            }
        }
        // A missing session exits non-zero and is healthy; exact-path process teardown
        // below is the authoritative verification that no workspace-owned client remains.
    }
    Ok(())
}

fn remove_owned_runtime_files(workspace: &Path) -> Result<(), WorkspaceError> {
    for name in [LOCK_FILE, LEGACY_LOCK_FILE, RENDEZVOUS_FILE] {
        let path = workspace.join(name);
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(map_io_error(
                    error,
                    format!("could not remove owned runtime file {}", path.display()),
                ))
            }
        }
    }
    Ok(())
}

fn install_helpers(home: &Path, target: &Path) -> Result<(), WorkspaceError> {
    let source = home.join(".graphcode").join("bin");
    if !source.is_dir() {
        return Err(WorkspaceError::HelpersUnavailable(
            source.display().to_string(),
        ));
    }
    let destination = target.join("bin");
    fs::create_dir_all(&destination).map_err(|error| WorkspaceError::Io(error.to_string()))?;
    for entry in fs::read_dir(&source).map_err(|error| WorkspaceError::Io(error.to_string()))? {
        let entry = entry.map_err(|error| WorkspaceError::Io(error.to_string()))?;
        if !entry.path().is_file() {
            continue;
        }
        let target_file = destination.join(entry.file_name());
        if !target_file.exists() {
            fs::copy(entry.path(), target_file)
                .map_err(|error| WorkspaceError::Io(error.to_string()))?;
        }
    }
    Ok(())
}

fn start_daemon(workspace: &Path) -> Result<(), WorkspaceError> {
    let daemon = workspace.join("bin").join(if cfg!(windows) {
        "graphcoded.exe"
    } else {
        "graphcoded"
    });
    if !daemon.is_file() {
        return Err(WorkspaceError::HelpersUnavailable(
            daemon.display().to_string(),
        ));
    }
    let mut command = Command::new(daemon);
    command
        .env("GRAPHCODE_SUPPORT_DIR", workspace)
        .env("ZMX_DIR", zmx_namespace_directory(workspace))
        .current_dir(workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    hide_console(&mut command);
    command
        .spawn()
        .map_err(|error| WorkspaceError::DaemonStart(error.to_string()))?;

    let secret = workspace.join(".graphcode-rendezvous.secret");
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        if fs::metadata(&secret).is_ok_and(|metadata| metadata.len() == 32) {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(WorkspaceError::DaemonTimeout)
}

fn workspace_is_open(path: &Path) -> bool {
    fs::read_to_string(path.join(LOCK_FILE))
        .ok()
        .and_then(|value| value.trim().parse::<u32>().ok())
        .is_some_and(process_is_running)
}

#[cfg(windows)]
fn process_is_running(pid: u32) -> bool {
    use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return false;
        }
        let mut code = 0;
        let running = GetExitCodeProcess(process, &mut code) != 0 && code == STILL_ACTIVE as u32;
        CloseHandle(process);
        running
    }
}

#[cfg(not(windows))]
fn process_is_running(_pid: u32) -> bool {
    false
}

#[cfg(windows)]
fn stop_scheduled_daemon(workspace: &Path) -> Result<(), WorkspaceError> {
    use crate::endpoint::current_windows_sid;
    let sid = current_windows_sid().map_err(|error| WorkspaceError::Io(error.to_string()))?;
    let support = workspace.to_string_lossy().to_lowercase();
    let support_hash = hex::encode(Sha256::digest(support.as_bytes()));
    let identity = format!("{sid}|{support_hash}");
    let identity_hash = hex::encode(Sha256::digest(identity.as_bytes()));
    let task = format!(r"GraphCode\graphcoded-{}", &identity_hash[..32]);
    let _ = Command::new("schtasks.exe")
        .args(["/End", "/TN", &task])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    let output = Command::new("schtasks.exe")
        .args(["/Delete", "/TN", &task, "/F"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| WorkspaceError::Io(error.to_string()))?;
    if !output.status.success() {
        let message = String::from_utf8_lossy(&output.stderr);
        if !message.contains("cannot find") && !message.contains("does not exist") {
            return Err(WorkspaceError::Io(message.trim().to_string()));
        }
    }
    Ok(())
}

#[cfg(not(windows))]
fn stop_scheduled_daemon(_workspace: &Path) -> Result<(), WorkspaceError> {
    Ok(())
}

#[cfg(windows)]
fn inspect_pid(pid: u32) -> PidState {
    use windows_sys::Win32::Foundation::{
        CloseHandle, GetLastError, ERROR_ACCESS_DENIED, STILL_ACTIVE,
    };
    use windows_sys::Win32::System::Threading::{
        GetExitCodeProcess, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            let error = GetLastError();
            if error == ERROR_ACCESS_DENIED {
                return PidState::Uncertain(format!(
                    "access was denied while inspecting process {pid}"
                ));
            }
            return PidState::Exited;
        }
        let mut code = 0;
        let state = if GetExitCodeProcess(process, &mut code) == 0 {
            PidState::Uncertain(format!("could not inspect process {pid}"))
        } else if code == STILL_ACTIVE as u32 {
            PidState::Running
        } else {
            PidState::Exited
        };
        CloseHandle(process);
        state
    }
}

#[cfg(not(windows))]
fn inspect_pid(pid: u32) -> PidState {
    if process_is_running(pid) {
        PidState::Running
    } else {
        PidState::Exited
    }
}

#[cfg(windows)]
fn preflight_process_ownership(workspace: &Path) -> Result<(), WorkspaceError> {
    for executable in ["graphcoded.exe", "zmx.exe"] {
        let _ = owned_processes(workspace, executable)?;
    }
    Ok(())
}

#[cfg(not(windows))]
fn preflight_process_ownership(_workspace: &Path) -> Result<(), WorkspaceError> {
    Ok(())
}

#[cfg(windows)]
fn verify_no_owned_processes(workspace: &Path) -> Result<(), WorkspaceError> {
    for executable in ["graphcoded.exe", "zmx.exe"] {
        let processes = owned_processes(workspace, executable)?;
        if !processes.is_empty() {
            return Err(WorkspaceError::TeardownIncomplete(format!(
                "{} still has running process ids {}",
                executable,
                processes
                    .iter()
                    .map(|process| process.pid.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            )));
        }
    }
    Ok(())
}

#[cfg(not(windows))]
fn verify_no_owned_processes(_workspace: &Path) -> Result<(), WorkspaceError> {
    Ok(())
}

#[cfg(windows)]
struct OwnedProcess {
    handle: windows_sys::Win32::Foundation::HANDLE,
    pid: u32,
    executable: String,
    expected_path: PathBuf,
}

#[cfg(not(windows))]
struct OwnedProcess;

#[cfg(windows)]
impl OwnedProcess {
    fn image_path(&self) -> Result<PathBuf, WorkspaceError> {
        use windows_sys::Win32::Foundation::GetLastError;
        use windows_sys::Win32::System::Threading::QueryFullProcessImageNameW;

        let mut buffer = vec![0u16; 32_768];
        let mut length = buffer.len() as u32;
        unsafe {
            if QueryFullProcessImageNameW(self.handle, 0, buffer.as_mut_ptr(), &mut length) == 0 {
                let error = GetLastError();
                if error == windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED {
                    return Err(WorkspaceError::PermissionDenied(format!(
                        "could not resolve {} process {}",
                        self.executable, self.pid
                    )));
                }
                return Err(WorkspaceError::ProcessOwnershipUncertain(format!(
                    "could not resolve {} process {} (Windows error {error})",
                    self.executable, self.pid
                )));
            }
        }
        canonical_existing(Path::new(&String::from_utf16_lossy(
            &buffer[..length as usize],
        )))
    }

    fn is_running(&self) -> Result<bool, WorkspaceError> {
        use windows_sys::Win32::Foundation::{GetLastError, STILL_ACTIVE};
        use windows_sys::Win32::System::Threading::GetExitCodeProcess;

        let mut exit_code = 0;
        unsafe {
            if GetExitCodeProcess(self.handle, &mut exit_code) == 0 {
                return Err(WorkspaceError::ProcessOwnershipUncertain(format!(
                    "could not inspect {} process {} (Windows error {})",
                    self.executable,
                    self.pid,
                    GetLastError()
                )));
            }
        }
        Ok(exit_code == STILL_ACTIVE as u32)
    }

    fn terminate(self) -> Result<(), WorkspaceError> {
        use windows_sys::Win32::Foundation::{GetLastError, WAIT_OBJECT_0};
        use windows_sys::Win32::System::Threading::{TerminateProcess, WaitForSingleObject};

        if !self.is_running()? {
            return Ok(());
        }
        let actual = match self.image_path() {
            Ok(path) => path,
            Err(_) if !self.is_running()? => return Ok(()),
            Err(error) => return Err(error),
        };
        if !same_path(&actual, &self.expected_path) {
            return Err(WorkspaceError::ProcessOwnershipUncertain(format!(
                "{} process {} changed executable identity before termination",
                self.executable, self.pid
            )));
        }
        unsafe {
            if TerminateProcess(self.handle, 1) == 0 {
                if !self.is_running()? {
                    return Ok(());
                }
                return Err(WorkspaceError::TeardownIncomplete(format!(
                    "could not stop {} process {} (Windows error {})",
                    self.executable,
                    self.pid,
                    GetLastError()
                )));
            }
            if WaitForSingleObject(self.handle, 5_000) != WAIT_OBJECT_0 {
                return Err(WorkspaceError::TeardownIncomplete(format!(
                    "{} process {} did not stop within five seconds",
                    self.executable, self.pid
                )));
            }
        }
        Ok(())
    }
}

#[cfg(windows)]
impl Drop for OwnedProcess {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::Foundation::CloseHandle(self.handle);
        }
    }
}

#[cfg(windows)]
fn owned_processes(
    workspace: &Path,
    executable: &str,
) -> Result<Vec<OwnedProcess>, WorkspaceError> {
    use std::mem::size_of;
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
    };

    const PROCESS_SYNCHRONIZE: u32 = 0x0010_0000;
    let expected = canonical_existing(&workspace.join("bin").join(executable))?;
    let mut owned = Vec::new();
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(WorkspaceError::ProcessOwnershipUncertain(
                "could not enumerate processes".into(),
            ));
        }
        struct Snapshot(windows_sys::Win32::Foundation::HANDLE);
        impl Drop for Snapshot {
            fn drop(&mut self) {
                unsafe {
                    CloseHandle(self.0);
                }
            }
        }
        let _snapshot = Snapshot(snapshot);
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
        let mut has_entry = Process32FirstW(snapshot, &mut entry) != 0;
        if !has_entry {
            return Err(WorkspaceError::ProcessOwnershipUncertain(format!(
                "could not read the process snapshot (Windows error {})",
                GetLastError()
            )));
        }
        while has_entry {
            let length = entry
                .szExeFile
                .iter()
                .position(|character| *character == 0)
                .unwrap_or(entry.szExeFile.len());
            let name = String::from_utf16_lossy(&entry.szExeFile[..length]);
            if name.eq_ignore_ascii_case(executable) {
                let process = OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | PROCESS_SYNCHRONIZE,
                    0,
                    entry.th32ProcessID,
                );
                if process.is_null() {
                    let error = GetLastError();
                    if error == windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED {
                        return Err(WorkspaceError::PermissionDenied(format!(
                            "could not inspect {executable} process {}",
                            entry.th32ProcessID
                        )));
                    }
                    return Err(WorkspaceError::ProcessOwnershipUncertain(format!(
                        "could not inspect {executable} process {} (Windows error {error})",
                        entry.th32ProcessID
                    )));
                }
                let process = OwnedProcess {
                    handle: process,
                    pid: entry.th32ProcessID,
                    executable: executable.to_string(),
                    expected_path: expected.clone(),
                };
                let actual = process.image_path()?;
                if same_path(&actual, &expected) {
                    owned.push(process);
                }
            }
            has_entry = Process32NextW(snapshot, &mut entry) != 0;
        }
    }
    Ok(owned)
}

#[cfg(not(windows))]
fn owned_processes(
    _workspace: &Path,
    _executable: &str,
) -> Result<Vec<OwnedProcess>, WorkspaceError> {
    Ok(Vec::new())
}

#[cfg(windows)]
fn terminate_owned_processes(processes: Vec<OwnedProcess>) -> Result<(), WorkspaceError> {
    for process in processes {
        process.terminate()?;
    }
    Ok(())
}

#[cfg(not(windows))]
fn terminate_owned_processes(_processes: Vec<OwnedProcess>) -> Result<(), WorkspaceError> {
    Ok(())
}

fn recovery_root(home: &Path) -> Result<PathBuf, WorkspaceError> {
    let home = canonical_existing(home)?;
    let root = home.join(RECOVERY_DIRECTORY);
    match fs::create_dir(&root) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => {
            return Err(map_io_error(
                error,
                format!("could not create recovery directory {}", root.display()),
            ))
        }
    }
    let metadata = fs::symlink_metadata(&root).map_err(|error| {
        map_io_error(
            error,
            format!("could not inspect recovery directory {}", root.display()),
        )
    })?;
    if metadata_is_reparse_point(&metadata) || !metadata.is_dir() {
        return Err(WorkspaceError::RecoveryUncertain(format!(
            "{} is not a plain local directory",
            root.display()
        )));
    }
    let root = canonical_existing(&root)?;
    if root.parent().is_none_or(|parent| !same_path(parent, &home)) {
        return Err(WorkspaceError::RecoveryUncertain(format!(
            "{} is not a direct child of {}",
            root.display(),
            home.display()
        )));
    }
    Ok(root)
}

fn recovery_destination(home: &Path, target: &Path) -> Result<PathBuf, WorkspaceError> {
    let root = recovery_root(home)?;
    verify_local_recovery_volume(target, &root)?;
    probe_recovery_rename(&root)?;
    let name = target
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            WorkspaceError::RecoveryUncertain(format!(
                "{} has no valid recovery name",
                target.display()
            ))
        })?;
    for _ in 0..16 {
        let candidate = root.join(format!("{name}-{}", Uuid::new_v4()));
        if !candidate.exists() {
            return Ok(candidate);
        }
    }
    Err(WorkspaceError::RecoveryUncertain(
        "could not allocate a unique recovery location".into(),
    ))
}

fn validate_recovery_destination(
    home: &Path,
    target: &Path,
    expected: &str,
) -> Result<PathBuf, WorkspaceError> {
    let root = recovery_root(home)?;
    verify_local_recovery_volume(target, &root)?;
    probe_recovery_rename(&root)?;
    let expected = PathBuf::from(expected);
    let parent = expected
        .parent()
        .ok_or_else(|| WorkspaceError::ConfirmationMismatch {
            expected: expected.display().to_string(),
            actual: root.display().to_string(),
        })?;
    let parent = canonical_existing(parent)?;
    if !same_path(&parent, &root) || expected.exists() {
        return Err(WorkspaceError::ConfirmationMismatch {
            expected: expected.display().to_string(),
            actual: root.display().to_string(),
        });
    }
    if expected.file_name().is_none() {
        return Err(WorkspaceError::RecoveryUncertain(
            "the confirmed recovery destination has no file name".into(),
        ));
    }
    Ok(root.join(expected.file_name().expect("checked above")))
}

fn probe_recovery_rename(root: &Path) -> Result<(), WorkspaceError> {
    let source = root.join(format!(".graphcode-recovery-probe-{}", Uuid::new_v4()));
    let destination = source.with_extension("moved");
    fs::create_dir(&source).map_err(|error| {
        map_io_error(
            error,
            format!("could not create a recovery probe in {}", root.display()),
        )
    })?;
    let result = fs::rename(&source, &destination).and_then(|()| fs::remove_dir(&destination));
    if let Err(error) = result {
        let _ = fs::remove_dir(&source);
        let _ = fs::remove_dir(&destination);
        return Err(map_io_error(
            error,
            format!(
                "could not prove atomic rename permission in {}",
                root.display()
            ),
        ));
    }
    Ok(())
}

#[cfg(windows)]
fn verify_local_recovery_volume(target: &Path, recovery_root: &Path) -> Result<(), WorkspaceError> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{GetDriveTypeW, GetVolumePathNameW};
    use windows_sys::Win32::System::WindowsProgramming::DRIVE_FIXED;

    fn volume_root(path: &Path) -> Result<Vec<u16>, WorkspaceError> {
        let wide: Vec<u16> = path
            .as_os_str()
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let mut root = vec![0u16; 32_768];
        unsafe {
            if GetVolumePathNameW(wide.as_ptr(), root.as_mut_ptr(), root.len() as u32) == 0 {
                return Err(WorkspaceError::RecoveryUncertain(format!(
                    "could not determine the volume for {}",
                    path.display()
                )));
            }
        }
        Ok(root)
    }

    let target_root = volume_root(target)?;
    let recovery_volume = volume_root(recovery_root)?;
    unsafe {
        if GetDriveTypeW(target_root.as_ptr()) != DRIVE_FIXED
            || GetDriveTypeW(recovery_volume.as_ptr()) != DRIVE_FIXED
        {
            return Err(WorkspaceError::RecoveryUncertain(
                "recoverable deletion requires a fixed local volume".into(),
            ));
        }
    }
    let target_identity = StableDirectory::open(target)?;
    let recovery_identity = StableDirectory::open(recovery_root)?;
    if target_identity.identity.volume_serial != recovery_identity.identity.volume_serial {
        return Err(WorkspaceError::RecoveryUncertain(
            "workspace and recovery directory are not on the same volume".into(),
        ));
    }
    Ok(())
}

#[cfg(not(windows))]
fn verify_local_recovery_volume(
    _target: &Path,
    _recovery_root: &Path,
) -> Result<(), WorkspaceError> {
    Ok(())
}

#[cfg(windows)]
fn move_to_recovery(
    source: &Path,
    destination: &Path,
    stable: &StableDirectory,
) -> Result<Option<String>, WorkspaceError> {
    stable.verify_path(source)?;
    stable.rename_to(destination)?;
    let mut warnings = Vec::new();
    if let Err(error) = stable.verify_path(destination) {
        warnings.push(format!(
            "workspace recovery committed at {}, but destination identity verification failed: {error}",
            destination.display()
        ));
    }
    if source.exists() {
        warnings.push(format!(
            "workspace recovery committed at {}, but the original path still appears to exist",
            destination.display()
        ));
    }
    Ok((!warnings.is_empty()).then(|| warnings.join(" ")))
}

#[cfg(not(windows))]
fn move_to_recovery(
    source: &Path,
    destination: &Path,
    stable: &StableDirectory,
) -> Result<Option<String>, WorkspaceError> {
    stable.verify_path(source)?;
    fs::rename(source, destination).map_err(|error| {
        map_io_error(
            error,
            format!("could not move {} to recovery", source.display()),
        )
    })?;
    Ok(stable.verify_path(destination).err().map(|error| {
        format!(
            "workspace recovery committed at {}, but destination identity verification failed: {error}",
            destination.display()
        )
    }))
}

#[cfg(windows)]
fn hide_console(command: &mut Command) {
    use std::os::windows::process::CommandExt;
    command.creation_flags(0x0800_0000);
}

#[cfg(not(windows))]
fn hide_console(_command: &mut Command) {}

fn same_path(left: &Path, right: &Path) -> bool {
    left.to_string_lossy()
        .trim_end_matches(['/', '\\'])
        .eq_ignore_ascii_case(right.to_string_lossy().trim_end_matches(['/', '\\']))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_names_become_bounded_ascii_slugs() {
        assert_eq!(slug("  Research / Builds  ").unwrap(), "research-builds");
        assert!(slug("🧪").is_err());
        assert!(slug(&"a".repeat(40)).unwrap().len() <= 32);
    }

    #[test]
    fn workspace_contents_include_graph_and_layout_sessions() {
        let root = std::env::temp_dir().join(format!("graphcode-workspace-{}", Uuid::new_v4()));
        let projects = root.join("projects");
        let layouts = root.join("terminal-layouts");
        fs::create_dir_all(&projects).unwrap();
        fs::create_dir_all(&layouts).unwrap();
        fs::write(
            projects.join("a.json"),
            br#"{"nodes":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"},{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}]}"#,
        )
        .unwrap();
        fs::write(projects.join("settings.json"), br#"{"value":1}"#).unwrap();
        fs::write(
            layouts.join("a.json"),
            br#"{"tabs":[{"surfaces":[{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"},{"id":"cccccccc-cccc-cccc-cccc-cccccccccccc"}]}]}"#,
        )
        .unwrap();

        let contents = workspace_contents(&root);
        assert_eq!(contents.projects, 1);
        assert_eq!(contents.loops, 2);
        assert_eq!(
            contents.session_names,
            vec![
                "graphcode-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                "graphcode-BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                "graphcode-CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
            ]
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn deletion_target_must_be_a_named_direct_child_with_helpers() {
        let root = std::env::temp_dir().join(format!("graphcode-delete-{}", Uuid::new_v4()));
        let home = root.join("home");
        let default = home.join(".graphcode");
        let target = home.join(".graphcode-research");
        for workspace in [&default, &target] {
            fs::create_dir_all(workspace.join("bin")).unwrap();
            fs::write(workspace.join("bin").join("graphcoded.exe"), b"test").unwrap();
            fs::write(workspace.join("bin").join("zmx.exe"), b"test").unwrap();
        }

        assert_eq!(
            validate_deletion_target(&home, &default, target.to_str().unwrap())
                .unwrap()
                .file_name()
                .unwrap(),
            ".graphcode-research"
        );
        assert!(matches!(
            validate_deletion_target(&home, &default, default.to_str().unwrap()),
            Err(WorkspaceError::DefaultWorkspaceDeletion)
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn live_workspace_lock_refuses_deletion() {
        let root = std::env::temp_dir().join(format!("graphcode-lock-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join(LOCK_FILE), std::process::id().to_string()).unwrap();

        assert!(matches!(
            inspect_workspace_locks(&root),
            Err(WorkspaceError::OpenWorkspace)
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn stable_directory_identity_rejects_path_replacement() {
        let root = std::env::temp_dir().join(format!("graphcode-identity-{}", Uuid::new_v4()));
        let target = root.join("target");
        let original = root.join("original");
        fs::create_dir_all(&target).unwrap();
        let stable = StableDirectory::open(&target).unwrap();

        fs::rename(&target, &original).unwrap();
        fs::create_dir(&target).unwrap();
        assert!(matches!(
            stable.verify_path(&target),
            Err(WorkspaceError::PathUncertain(_))
        ));

        drop(stable);
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn handle_rename_moves_verified_directory_not_path_replacement() {
        let root = std::env::temp_dir().join(format!("graphcode-handle-rename-{}", Uuid::new_v4()));
        let source = root.join("workspace");
        let displaced = root.join("workspace-displaced");
        let recovery = root.join("recovery");
        let destination = recovery.join("workspace-recovered");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir(&recovery).unwrap();
        fs::write(source.join("verified-object"), b"verified").unwrap();
        let stable = StableDirectory::open(&source).unwrap();
        stable.verify_path(&source).unwrap();

        fs::rename(&source, &displaced).unwrap();
        fs::create_dir(&source).unwrap();
        fs::write(source.join("replacement-object"), b"replacement").unwrap();

        stable.rename_to(&destination).unwrap();

        assert!(source.join("replacement-object").is_file());
        assert!(!source.join("verified-object").exists());
        assert!(destination.join("verified-object").is_file());
        assert!(!destination.join("replacement-object").exists());
        stable.verify_path(&destination).unwrap();
        drop(stable);
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn handle_rename_refuses_recovery_destination_collision() {
        let root =
            std::env::temp_dir().join(format!("graphcode-handle-collision-{}", Uuid::new_v4()));
        let source = root.join("workspace");
        let recovery = root.join("recovery");
        let destination = recovery.join("workspace-recovered");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir(&recovery).unwrap();
        fs::create_dir(&destination).unwrap();
        fs::write(source.join("verified-object"), b"verified").unwrap();
        fs::write(destination.join("existing-object"), b"existing").unwrap();
        let stable = StableDirectory::open(&source).unwrap();

        assert!(matches!(
            stable.rename_to(&destination),
            Err(WorkspaceError::RecoveryUncertain(_))
        ));
        assert!(source.join("verified-object").is_file());
        assert!(destination.join("existing-object").is_file());
        drop(stable);
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn recovery_destination_must_stay_in_graphcode_recovery_root() {
        let root = std::env::temp_dir().join(format!("graphcode-recovery-{}", Uuid::new_v4()));
        let home = root.join("home");
        let target = home.join(".graphcode-research");
        fs::create_dir_all(&target).unwrap();
        let outside = home.join("not-recovery").join("workspace");
        fs::create_dir_all(outside.parent().unwrap()).unwrap();

        assert!(matches!(
            validate_recovery_destination(&home, &target, outside.to_str().unwrap()),
            Err(WorkspaceError::ConfirmationMismatch { .. })
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn zmx_namespace_record_is_random_and_workspace_scoped() {
        let root = std::env::temp_dir().join(format!("graphcode-zmx-owner-{}", Uuid::new_v4()));
        let first = root.join(".graphcode-first");
        let second = root.join(".graphcode-second");
        fs::create_dir_all(&first).unwrap();
        fs::create_dir_all(&second).unwrap();
        initialize_zmx_namespace(&first).unwrap();

        let marker = fs::read_to_string(first.join(ZMX_NAMESPACE_MARKER)).unwrap();
        let secret = marker.lines().nth(2).unwrap();
        assert_eq!(secret.len(), 64);
        assert!(secret.bytes().all(|byte| byte.is_ascii_hexdigit()));

        fs::create_dir(second.join(ZMX_NAMESPACE_DIRECTORY)).unwrap();
        fs::write(second.join(ZMX_NAMESPACE_MARKER), marker).unwrap();
        assert!(matches!(
            verify_zmx_namespace(&second),
            Err(WorkspaceError::OwnershipUncertain(_))
        ));
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn workspace_mutations_share_one_cross_thread_mutex() {
        use std::sync::mpsc;

        let root = std::env::temp_dir().join(format!("graphcode-mutex-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let first = WorkspaceMutationGuard::acquire(&root).unwrap();
        let second_root = root.clone();
        let (sender, receiver) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let _second = WorkspaceMutationGuard::acquire(&second_root).unwrap();
            sender.send(()).unwrap();
        });

        assert!(receiver.recv_timeout(Duration::from_millis(150)).is_err());
        drop(first);
        receiver.recv_timeout(Duration::from_secs(2)).unwrap();
        worker.join().unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn deletion_transaction_cleans_runtime_files_before_recoverable_move() {
        let root = std::env::temp_dir().join(format!("graphcode-delete-flow-{}", Uuid::new_v4()));
        let home = root.join("home");
        let default = home.join(".graphcode");
        let target = home.join(".graphcode-research");
        let recovered = home.join(RECOVERY_DIRECTORY).join("research-test-recovery");
        for workspace in [&default, &target] {
            fs::create_dir_all(workspace.join("bin")).unwrap();
            fs::write(workspace.join("bin").join("graphcoded.exe"), b"test").unwrap();
            fs::write(workspace.join("bin").join("zmx.exe"), b"test").unwrap();
        }
        initialize_zmx_namespace(&target).unwrap();
        fs::create_dir_all(target.join("projects")).unwrap();
        fs::write(
            target.join("projects").join("forged.json"),
            br#"{"nodes":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"}]}"#,
        )
        .unwrap();
        assert_eq!(workspace_contents(&target).session_names.len(), 1);
        fs::write(target.join(LOCK_FILE), "999999").unwrap();
        fs::write(target.join(LEGACY_LOCK_FILE), "999999").unwrap();
        fs::write(target.join(RENDEZVOUS_FILE), [7u8; 32]).unwrap();
        let lease_path = deletion_lease_path(&target).unwrap();
        let expected = canonical_existing(&target).unwrap();
        let identity_token = StableDirectory::open(&target).unwrap().confirmation_token();

        let result = delete_from(
            &home,
            &default,
            target.to_str().unwrap(),
            expected.to_str().unwrap(),
            recovered.to_str().unwrap(),
            &identity_token,
            // Editable graph IDs are impact metadata only; the trusted namespace
            // is the sole source of sessions authorized for teardown.
            |_| Ok(Vec::new()),
            move_to_recovery,
            DeletionLease::cleanup_after_commit,
        )
        .unwrap();

        assert!(result.committed);
        assert!(result.cleanup_warning.is_none());
        assert!(!target.exists());
        assert!(recovered.is_dir());
        assert!(!recovered.join(LOCK_FILE).exists());
        assert!(!recovered.join(LEGACY_LOCK_FILE).exists());
        assert!(!recovered.join(RENDEZVOUS_FILE).exists());
        assert!(!lease_path.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn deletion_confirmation_rejects_replacement_at_the_same_path() {
        let root =
            std::env::temp_dir().join(format!("graphcode-delete-replaced-{}", Uuid::new_v4()));
        let home = root.join("home");
        let default = home.join(".graphcode");
        let target = home.join(".graphcode-research");
        let original = home.join(".graphcode-research-original");
        for workspace in [&default, &target] {
            fs::create_dir_all(workspace.join("bin")).unwrap();
            fs::write(workspace.join("bin").join("graphcoded.exe"), b"test").unwrap();
            fs::write(workspace.join("bin").join("zmx.exe"), b"test").unwrap();
        }
        let expected = canonical_existing(&target).unwrap();
        let identity_token = StableDirectory::open(&target).unwrap().confirmation_token();

        fs::rename(&target, &original).unwrap();
        fs::create_dir_all(target.join("bin")).unwrap();
        fs::write(target.join("bin").join("graphcoded.exe"), b"replacement").unwrap();
        fs::write(target.join("bin").join("zmx.exe"), b"replacement").unwrap();
        fs::write(target.join("replacement-marker"), b"untouched").unwrap();

        let result = delete_from(
            &home,
            &default,
            target.to_str().unwrap(),
            expected.to_str().unwrap(),
            home.join(RECOVERY_DIRECTORY)
                .join("unused")
                .to_str()
                .unwrap(),
            &identity_token,
            |_| panic!("session enumeration must not begin after identity mismatch"),
            |_, _, _| panic!("recovery move must not begin after identity mismatch"),
            |_| panic!("lease cleanup must not begin after identity mismatch"),
        );

        assert!(matches!(
            result,
            Err(WorkspaceError::ConfirmationIdentityMismatch)
        ));
        assert!(target.join("replacement-marker").is_file());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    fn committed_recovery_returns_cleanup_warning_instead_of_failure() {
        let root =
            std::env::temp_dir().join(format!("graphcode-delete-committed-{}", Uuid::new_v4()));
        let home = root.join("home");
        let default = home.join(".graphcode");
        let target = home.join(".graphcode-research");
        let recovered = home.join(RECOVERY_DIRECTORY).join("research-committed");
        for workspace in [&default, &target] {
            fs::create_dir_all(workspace.join("bin")).unwrap();
            fs::write(workspace.join("bin").join("graphcoded.exe"), b"test").unwrap();
            fs::write(workspace.join("bin").join("zmx.exe"), b"test").unwrap();
        }
        initialize_zmx_namespace(&target).unwrap();
        let expected = canonical_existing(&target).unwrap();
        let identity_token = StableDirectory::open(&target).unwrap().confirmation_token();
        let lease_path = deletion_lease_path(&target).unwrap();

        let result = delete_from(
            &home,
            &default,
            target.to_str().unwrap(),
            expected.to_str().unwrap(),
            recovered.to_str().unwrap(),
            &identity_token,
            |_| Ok(Vec::new()),
            move_to_recovery,
            |lease| {
                lease.cleanup_after_commit_with(|_| {
                    Err(io::Error::other("simulated post-commit cleanup failure"))
                })
            },
        )
        .unwrap();

        assert!(result.committed);
        assert!(result
            .cleanup_warning
            .as_deref()
            .is_some_and(|warning| warning.contains("recovery committed")));
        assert!(!target.exists());
        assert!(recovered.is_dir());
        assert!(lease_path.is_file());
        fs::remove_file(lease_path).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "atomically moves only an explicitly approved disposable directory"]
    fn recovery_move_uses_only_disposable_directory() {
        let approved = std::env::var_os("GRAPHCODE_TEST_DISPOSABLE_ROOT")
            .map(PathBuf::from)
            .expect("GRAPHCODE_TEST_DISPOSABLE_ROOT must name the approved session folder");
        let approved = canonical_existing(&approved).unwrap();
        let root = approved.join(format!("graphcode-recovery-test-{}", Uuid::new_v4()));
        let target = root.join("workspace");
        let recovery = root.join("recovery");
        fs::create_dir(&root).unwrap();
        fs::create_dir(&target).unwrap();
        fs::create_dir(&recovery).unwrap();
        fs::write(target.join("marker.txt"), b"disposable").unwrap();
        let destination = recovery.join("workspace-recovered");
        let stable = StableDirectory::open(&target).unwrap();

        verify_local_recovery_volume(&target, &recovery).unwrap();
        assert!(move_to_recovery(&target, &destination, &stable)
            .unwrap()
            .is_none());
        assert!(!target.exists());
        assert!(destination.join("marker.txt").is_file());
        fs::remove_dir_all(root).unwrap();
    }
}
