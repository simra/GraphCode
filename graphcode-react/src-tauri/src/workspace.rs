use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;
use sha2::{Digest, Sha256};
use thiserror::Error;
#[cfg(test)]
use uuid::Uuid;

use crate::endpoint;

const DIRECTORY_PREFIX: &str = ".graphcode-";
const LOCK_FILE: &str = ".graphcode-react.lock";
const LEGACY_LOCK_FILE: &str = "app.pid";
const DELETION_LOCK_PREFIX: &str = ".graphcode-deleting-";
const RENDEZVOUS_FILE: &str = ".graphcode-rendezvous.secret";

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
    #[error("failed to move the workspace to the Windows Recycle Bin: {0}")]
    RecycleBin(String),
    #[error("workspace confirmation no longer matches the canonical path (expected {expected}, found {actual})")]
    ConfirmationMismatch { expected: String, actual: String },
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
    pub projects: usize,
    pub loops: usize,
    pub terminal_sessions: usize,
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
    summarize(&path, &current_directory()?, &home)
}

pub fn rename(id: &str, name: &str) -> Result<WorkspaceSummary, WorkspaceError> {
    let home = home_directory()?;
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
    summarize(&destination, &current, &home)
}

pub fn delete(id: &str, expected_path: &str) -> Result<(), WorkspaceError> {
    delete_from(
        &home_directory()?,
        &current_directory()?,
        id,
        expected_path,
        move_to_recycle_bin,
    )
}

pub fn prepare_delete(id: &str) -> Result<WorkspaceDeletionPlan, WorkspaceError> {
    let home = home_directory()?;
    let current = current_directory()?;
    let target = validate_deletion_target(&home, &current, id)?;
    inspect_workspace_locks(&target)?;
    preflight_process_ownership(&target)?;
    let contents = workspace_contents(&target);
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
        projects: contents.projects,
        loops: contents.loops,
        terminal_sessions: contents.session_names.len(),
    })
}

pub fn open(id: &str) -> Result<(), WorkspaceError> {
    let home = home_directory()?;
    let target = resolve_known(&home, id)?;
    if same_path(&target, &current_directory()?) {
        return Ok(());
    }
    ensure_not_deleting(&target)?;
    install_helpers(&home, &target)?;
    start_daemon(&target)?;

    let executable =
        std::env::current_exe().map_err(|error| WorkspaceError::AppStart(error.to_string()))?;
    let mut command = Command::new(executable);
    command
        .env("GRAPHCODE_SUPPORT_DIR", &target)
        .current_dir(&target)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    hide_console(&mut command);
    command
        .spawn()
        .map_err(|error| WorkspaceError::AppStart(error.to_string()))?;
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

fn delete_from<F>(
    home: &Path,
    current: &Path,
    id: &str,
    expected_path: &str,
    recycle: F,
) -> Result<(), WorkspaceError>
where
    F: FnOnce(&Path) -> Result<(), WorkspaceError>,
{
    let target = validate_deletion_target(home, current, id)?;
    let confirmed = canonical_existing(Path::new(expected_path))?;
    if !same_path(&target, &confirmed) {
        return Err(WorkspaceError::ConfirmationMismatch {
            expected: expected_path.to_string(),
            actual: target.display().to_string(),
        });
    }

    inspect_workspace_locks(&target)?;
    preflight_process_ownership(&target)?;
    let lease = DeletionLease::acquire(&target)?;
    inspect_workspace_locks(&target)?;

    stop_scheduled_daemon(&target)?;
    let contents = workspace_contents(&target);
    end_zmx_sessions(&target, &contents.session_names)?;
    terminate_owned_processes(&target, "zmx.exe")?;
    terminate_owned_processes(&target, "graphcoded.exe")?;
    verify_no_owned_processes(&target)?;
    remove_owned_runtime_files(&target)?;
    inspect_workspace_locks(&target)?;
    verify_no_owned_processes(&target)?;

    recycle(&target)?;
    lease.release()?;
    Ok(())
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

    fn release(self) -> Result<(), WorkspaceError> {
        fs::remove_file(&self.path).map_err(|error| {
            map_io_error(
                error,
                format!("could not release deletion lease {}", self.path.display()),
            )
        })?;
        self.armed
            .store(false, std::sync::atomic::Ordering::Release);
        Ok(())
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

fn end_zmx_sessions(workspace: &Path, session_names: &[String]) -> Result<(), WorkspaceError> {
    if session_names.is_empty() {
        return Ok(());
    }
    let zmx = workspace.join("bin").join("zmx.exe");
    for session_name in session_names {
        let mut child = Command::new(&zmx)
            .args(["kill", session_name, "--force"])
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
                    .map(u32::to_string)
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
fn owned_processes(workspace: &Path, executable: &str) -> Result<Vec<u32>, WorkspaceError> {
    use std::mem::size_of;
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };
    use windows_sys::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_QUERY_LIMITED_INFORMATION,
    };

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
                let process =
                    OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID);
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
                struct Process(windows_sys::Win32::Foundation::HANDLE);
                impl Drop for Process {
                    fn drop(&mut self) {
                        unsafe {
                            CloseHandle(self.0);
                        }
                    }
                }
                let process = Process(process);
                let mut buffer = vec![0u16; 32_768];
                let mut length = buffer.len() as u32;
                if QueryFullProcessImageNameW(process.0, 0, buffer.as_mut_ptr(), &mut length) == 0 {
                    let error = GetLastError();
                    if error == windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED {
                        return Err(WorkspaceError::PermissionDenied(format!(
                            "could not resolve {executable} process {}",
                            entry.th32ProcessID
                        )));
                    }
                    return Err(WorkspaceError::ProcessOwnershipUncertain(format!(
                        "could not resolve {executable} process {} (Windows error {error})",
                        entry.th32ProcessID
                    )));
                }
                let actual = canonical_existing(Path::new(&String::from_utf16_lossy(
                    &buffer[..length as usize],
                )))?;
                if same_path(&actual, &expected) {
                    owned.push(entry.th32ProcessID);
                }
            }
            has_entry = Process32NextW(snapshot, &mut entry) != 0;
        }
    }
    Ok(owned)
}

#[cfg(windows)]
fn terminate_owned_processes(workspace: &Path, executable: &str) -> Result<(), WorkspaceError> {
    use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, WAIT_OBJECT_0};
    use windows_sys::Win32::System::Threading::{
        OpenProcess, TerminateProcess, WaitForSingleObject, PROCESS_TERMINATE,
    };

    const PROCESS_SYNCHRONIZE: u32 = 0x0010_0000;
    for pid in owned_processes(workspace, executable)? {
        unsafe {
            let process = OpenProcess(PROCESS_TERMINATE | PROCESS_SYNCHRONIZE, 0, pid);
            if process.is_null() {
                return Err(WorkspaceError::PermissionDenied(format!(
                    "could not open {executable} process {pid} for termination (Windows error {})",
                    GetLastError()
                )));
            }
            struct Process(windows_sys::Win32::Foundation::HANDLE);
            impl Drop for Process {
                fn drop(&mut self) {
                    unsafe {
                        CloseHandle(self.0);
                    }
                }
            }
            let process = Process(process);
            if TerminateProcess(process.0, 1) == 0 {
                return Err(WorkspaceError::TeardownIncomplete(format!(
                    "could not stop {executable} process {pid} (Windows error {})",
                    GetLastError()
                )));
            }
            if WaitForSingleObject(process.0, 5_000) != WAIT_OBJECT_0 {
                return Err(WorkspaceError::TeardownIncomplete(format!(
                    "{executable} process {pid} did not stop within five seconds"
                )));
            }
        }
    }
    Ok(())
}

#[cfg(not(windows))]
fn terminate_owned_processes(_workspace: &Path, _executable: &str) -> Result<(), WorkspaceError> {
    Ok(())
}

#[cfg(windows)]
fn move_to_recycle_bin(path: &Path) -> Result<(), WorkspaceError> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::UI::Shell::{
        SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW,
    };

    let mut from: Vec<u16> = path.as_os_str().encode_wide().collect();
    from.extend([0, 0]);
    let mut operation: SHFILEOPSTRUCTW = unsafe { std::mem::zeroed() };
    operation.wFunc = FO_DELETE;
    operation.pFrom = from.as_ptr();
    operation.fFlags = (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT) as u16;
    let result = unsafe { SHFileOperationW(&mut operation) };
    if result != 0 {
        return Err(WorkspaceError::RecycleBin(format!(
            "Windows shell error {result}"
        )));
    }
    if operation.fAnyOperationsAborted != 0 {
        return Err(WorkspaceError::RecycleBin(
            "the Windows shell aborted the operation".into(),
        ));
    }
    if path.exists() {
        return Err(WorkspaceError::RecycleBin(format!(
            "{} still exists after the shell operation",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(not(windows))]
fn move_to_recycle_bin(_path: &Path) -> Result<(), WorkspaceError> {
    Err(WorkspaceError::RecycleBin(
        "recoverable workspace deletion is only implemented on Windows".into(),
    ))
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
    fn deletion_transaction_cleans_runtime_files_before_recoverable_move() {
        let root = std::env::temp_dir().join(format!("graphcode-delete-flow-{}", Uuid::new_v4()));
        let home = root.join("home");
        let default = home.join(".graphcode");
        let target = home.join(".graphcode-research");
        let recovered = root.join("recovered-workspace");
        for workspace in [&default, &target] {
            fs::create_dir_all(workspace.join("bin")).unwrap();
            fs::write(workspace.join("bin").join("graphcoded.exe"), b"test").unwrap();
            fs::write(workspace.join("bin").join("zmx.exe"), b"test").unwrap();
        }
        fs::write(target.join(LOCK_FILE), "999999").unwrap();
        fs::write(target.join(LEGACY_LOCK_FILE), "999999").unwrap();
        fs::write(target.join(RENDEZVOUS_FILE), [7u8; 32]).unwrap();
        let lease_path = deletion_lease_path(&target).unwrap();
        let expected = canonical_existing(&target).unwrap();

        delete_from(
            &home,
            &default,
            target.to_str().unwrap(),
            expected.to_str().unwrap(),
            |path| {
                fs::rename(path, &recovered).map_err(|error| {
                    WorkspaceError::RecycleBin(format!("test move failed: {error}"))
                })
            },
        )
        .unwrap();

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
    #[ignore = "moves an explicitly approved disposable directory to the Windows Recycle Bin"]
    fn recycle_bin_moves_only_disposable_directory() {
        let approved = std::env::var_os("GRAPHCODE_TEST_DISPOSABLE_ROOT")
            .map(PathBuf::from)
            .expect("GRAPHCODE_TEST_DISPOSABLE_ROOT must name the approved session folder");
        let approved = canonical_existing(&approved).unwrap();
        let target = approved.join(format!("graphcode-recycle-test-{}", Uuid::new_v4()));
        fs::create_dir(&target).unwrap();
        fs::write(target.join("marker.txt"), b"disposable").unwrap();

        move_to_recycle_bin(&target).unwrap();
        assert!(!target.exists());
    }
}
