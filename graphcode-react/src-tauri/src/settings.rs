use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use thiserror::Error;
use uuid::Uuid;

use crate::endpoint;

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error("failed to resolve the GraphCode settings path: {0}")]
    Path(String),
    #[error("failed to read GraphCode settings: {0}")]
    Read(String),
    #[error("settings.json must contain a JSON object")]
    InvalidShape,
    #[error("settings changed in another GraphCode window; reload and try again")]
    Conflict,
    #[error("failed to save GraphCode settings: {0}")]
    Write(String),
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsSnapshot {
    pub support_directory: String,
    pub file_path: String,
    pub revision: String,
    pub exists: bool,
    pub daemon_heartbeat_enabled: bool,
}

pub fn load() -> Result<SettingsSnapshot, SettingsError> {
    load_from(&settings_path()?)
}

pub fn set_daemon_heartbeat(
    expected_revision: &str,
    enabled: bool,
) -> Result<SettingsSnapshot, SettingsError> {
    let path = settings_path()?;
    set_daemon_heartbeat_at(&path, expected_revision, enabled)
}

fn set_daemon_heartbeat_at(
    path: &Path,
    expected_revision: &str,
    enabled: bool,
) -> Result<SettingsSnapshot, SettingsError> {
    let (bytes, exists) = read_optional(&path)?;
    if revision(&bytes) != expected_revision {
        return Err(SettingsError::Conflict);
    }
    let mut object = parse_object(&bytes, exists)?;
    object.insert("daemonHeartbeatEnabled".into(), Value::Bool(enabled));
    let output = serde_json::to_vec_pretty(&Value::Object(object)).map_err(|error| {
        SettingsError::Write(format!("could not encode settings.json: {error}"))
    })?;
    atomic_write(&path, &output)?;
    load_from(&path)
}

fn settings_path() -> Result<PathBuf, SettingsError> {
    endpoint::configured_support_directory()
        .map(|directory| directory.join("settings.json"))
        .map_err(|error| SettingsError::Path(error.to_string()))
}

fn load_from(path: &Path) -> Result<SettingsSnapshot, SettingsError> {
    let (bytes, exists) = read_optional(path)?;
    let object = parse_object(&bytes, exists)?;
    Ok(SettingsSnapshot {
        support_directory: path
            .parent()
            .unwrap_or_else(|| Path::new(""))
            .display()
            .to_string(),
        file_path: path.display().to_string(),
        revision: revision(&bytes),
        exists,
        daemon_heartbeat_enabled: object
            .get("daemonHeartbeatEnabled")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

fn read_optional(path: &Path) -> Result<(Vec<u8>, bool), SettingsError> {
    match fs::read(path) {
        Ok(bytes) => Ok((bytes, true)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok((Vec::new(), false)),
        Err(error) => Err(SettingsError::Read(error.to_string())),
    }
}

fn parse_object(bytes: &[u8], exists: bool) -> Result<Map<String, Value>, SettingsError> {
    if !exists || bytes.iter().all(u8::is_ascii_whitespace) {
        return Ok(Map::new());
    }
    serde_json::from_slice::<Value>(bytes)
        .map_err(|error| SettingsError::Read(error.to_string()))?
        .as_object()
        .cloned()
        .ok_or(SettingsError::InvalidShape)
}

fn revision(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), SettingsError> {
    let directory = path
        .parent()
        .ok_or_else(|| SettingsError::Write("settings path has no parent directory".into()))?;
    fs::create_dir_all(directory).map_err(|error| SettingsError::Write(error.to_string()))?;
    let temporary = directory.join(format!(".settings-{}.tmp", Uuid::new_v4()));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| SettingsError::Write(error.to_string()))?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|error| SettingsError::Write(error.to_string()))?;
        replace_file(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(windows)]
fn replace_file(source: &Path, destination: &Path) -> Result<(), SettingsError> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let source: Vec<u16> = source.as_os_str().encode_wide().chain([0]).collect();
    let destination: Vec<u16> = destination.as_os_str().encode_wide().chain([0]).collect();
    let result = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if result == 0 {
        return Err(SettingsError::Write(
            std::io::Error::last_os_error().to_string(),
        ));
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_file(source: &Path, destination: &Path) -> Result<(), SettingsError> {
    fs::rename(source, destination).map_err(|error| SettingsError::Write(error.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_path() -> PathBuf {
        std::env::temp_dir().join(format!("graphcode-settings-{}.json", Uuid::new_v4()))
    }

    #[test]
    fn heartbeat_update_preserves_unknown_settings() {
        let path = test_path();
        fs::write(&path, br#"{"futureSetting":{"value":7}}"#).unwrap();
        let before = load_from(&path).unwrap();
        let saved_snapshot = set_daemon_heartbeat_at(&path, &before.revision, true).unwrap();
        let saved: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();

        assert!(!before.daemon_heartbeat_enabled);
        assert!(saved_snapshot.daemon_heartbeat_enabled);
        assert_eq!(saved["futureSetting"]["value"], 7);
        assert_eq!(saved["daemonHeartbeatEnabled"], true);
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn heartbeat_update_rejects_a_stale_revision() {
        let path = test_path();
        fs::write(&path, b"{}").unwrap();
        let loaded = load_from(&path).unwrap();
        fs::write(&path, br#"{"changedElsewhere":true}"#).unwrap();

        assert!(matches!(
            set_daemon_heartbeat_at(&path, &loaded.revision, true),
            Err(SettingsError::Conflict)
        ));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn revisions_change_with_file_content() {
        assert_ne!(revision(b"{}"), revision(br#"{"changed":true}"#));
    }
}
