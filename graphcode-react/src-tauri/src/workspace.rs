use std::fs;
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
    #[error("that workspace is open in another GraphCode window")]
    OpenWorkspace,
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

pub fn open(id: &str) -> Result<(), WorkspaceError> {
    let home = home_directory()?;
    let target = resolve_known(&home, id)?;
    if same_path(&target, &current_directory()?) {
        return Ok(());
    }
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
    let (projects, loops) = project_counts(path);
    Ok(WorkspaceSummary {
        id: path.display().to_string(),
        name,
        path: path.display().to_string(),
        is_default,
        is_current: same_path(path, current),
        is_open: workspace_is_open(path),
        projects,
        loops,
    })
}

fn project_counts(workspace: &Path) -> (usize, usize) {
    let Ok(entries) = fs::read_dir(workspace.join("projects")) else {
        return (0, 0);
    };
    entries
        .filter_map(Result::ok)
        .filter(|entry| {
            entry
                .path()
                .extension()
                .is_some_and(|extension| extension == "json")
        })
        .filter_map(|entry| fs::read(entry.path()).ok())
        .filter_map(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .filter_map(|graph| graph.get("nodes").and_then(Value::as_array).map(Vec::len))
        .fold((0, 0), |(projects, loops), count| {
            (projects + 1, loops + count)
        })
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
    let requested = PathBuf::from(id);
    let current = current_directory()?;
    list_from(home, &current)?
        .into_iter()
        .find(|workspace| same_path(Path::new(&workspace.path), &requested))
        .map(|workspace| PathBuf::from(workspace.path))
        .ok_or(WorkspaceError::NotFound)
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
    fn project_counts_skip_non_graph_json() {
        let root = std::env::temp_dir().join(format!("graphcode-workspace-{}", Uuid::new_v4()));
        let projects = root.join("projects");
        fs::create_dir_all(&projects).unwrap();
        fs::write(projects.join("a.json"), br#"{"nodes":[{},{}]}"#).unwrap();
        fs::write(projects.join("settings.json"), br#"{"value":1}"#).unwrap();

        assert_eq!(project_counts(&root), (1, 2));
        fs::remove_dir_all(root).unwrap();
    }
}
