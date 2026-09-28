use std::{
    fs::{self, OpenOptions},
    io::{self, Write},
    path::Path,
};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

const HISTORY_FILE: &str = "navigation-history-v1.json";
const HISTORY_VERSION: u32 = 1;
const HISTORY_LIMIT: usize = 50;
const MAX_HISTORY_BYTES: usize = 512 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind")]
pub enum NavigationRoute {
    #[serde(rename = "project")]
    Project {
        #[serde(rename = "projectPath")]
        project_path: String,
        #[serde(rename = "compositePath")]
        composite_path: Vec<String>,
        #[serde(rename = "nodeId", skip_serializing_if = "Option::is_none")]
        node_id: Option<String>,
        #[serde(default, skip_serializing_if = "is_false")]
        terminal: bool,
    },
    #[serde(rename = "mailroom")]
    Mailroom {
        #[serde(rename = "projectPath")]
        project_path: String,
    },
    #[serde(rename = "quickChats")]
    QuickChats,
    #[serde(rename = "quickChat")]
    QuickChat { id: String },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct NavigationHistory {
    pub version: u32,
    pub entries: Vec<NavigationRoute>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<usize>,
}

impl Default for NavigationHistory {
    fn default() -> Self {
        Self {
            version: HISTORY_VERSION,
            entries: Vec::new(),
            cursor: None,
        }
    }
}

impl NavigationHistory {
    fn validate_and_clamp(mut self) -> io::Result<Self> {
        if self.version != HISTORY_VERSION {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!(
                    "unsupported navigation history version {}; expected {}",
                    self.version, HISTORY_VERSION
                ),
            ));
        }
        if self.entries.len() > HISTORY_LIMIT {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "navigation history exceeds the 50-entry client-state limit",
            ));
        }
        for route in &self.entries {
            route.validate()?;
        }
        self.cursor = match (self.cursor, self.entries.len()) {
            (_, 0) => None,
            (Some(cursor), count) => Some(cursor.min(count - 1)),
            (None, _) => None,
        };
        Ok(self)
    }
}

impl NavigationRoute {
    fn validate(&self) -> io::Result<()> {
        match self {
            Self::Project {
                project_path,
                composite_path,
                node_id,
                ..
            } => {
                validate_string(project_path, 32_768, "project path")?;
                if composite_path.len() > 64 {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "composite path exceeds the client-state depth limit",
                    ));
                }
                for node_id in composite_path {
                    validate_string(node_id, 8_192, "composite node ID")?;
                }
                if let Some(node_id) = node_id {
                    validate_string(node_id, 8_192, "node ID")?;
                }
            }
            Self::Mailroom { project_path } => {
                validate_string(project_path, 32_768, "project path")?;
            }
            Self::QuickChats => {}
            Self::QuickChat { id } => validate_string(id, 8_192, "Quick Chat ID")?,
        }
        Ok(())
    }
}

fn is_false(value: &bool) -> bool {
    !value
}

fn validate_string(value: &str, maximum: usize, label: &str) -> io::Result<()> {
    if value.trim().is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{label} is required"),
        ));
    }
    if value.len() > maximum {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{label} exceeds the client-state limit"),
        ));
    }
    Ok(())
}

pub fn load(state_directory: &Path) -> io::Result<NavigationHistory> {
    let raw = match fs::read(state_directory.join(HISTORY_FILE)) {
        Ok(raw) => raw,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(NavigationHistory::default());
        }
        Err(error) => return Err(error),
    };
    if raw.len() > MAX_HISTORY_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "navigation history file exceeds the 512 KiB client-state limit",
        ));
    }
    serde_json::from_slice::<NavigationHistory>(&raw)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
        .validate_and_clamp()
}

pub fn save(state_directory: &Path, history: NavigationHistory) -> io::Result<()> {
    let history = history.validate_and_clamp()?;
    fs::create_dir_all(state_directory)?;
    let target = state_directory.join(HISTORY_FILE);
    let temporary = state_directory.join(format!("{HISTORY_FILE}.{}.tmp", Uuid::new_v4()));
    let encoded = serde_json::to_vec_pretty(&history)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if encoded.len() > MAX_HISTORY_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "navigation history exceeds the 512 KiB client-state limit",
        ));
    }
    let mut file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&temporary)?;
    file.write_all(&encoded)?;
    file.sync_all()?;
    drop(file);
    if let Err(error) = replace_file(&temporary, &target) {
        let _ = fs::remove_file(&temporary);
        return Err(error);
    }
    Ok(())
}

#[cfg(not(windows))]
fn replace_file(temporary: &Path, target: &Path) -> io::Result<()> {
    fs::rename(temporary, target)
}

#[cfg(windows)]
fn replace_file(temporary: &Path, target: &Path) -> io::Result<()> {
    use std::{iter, os::windows::ffi::OsStrExt};
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let temporary: Vec<u16> = temporary
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect();
    let target: Vec<u16> = target
        .as_os_str()
        .encode_wide()
        .chain(iter::once(0))
        .collect();
    let moved = unsafe {
        MoveFileExW(
            temporary.as_ptr(),
            target.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temporary_directory() -> PathBuf {
        std::env::temp_dir().join(format!("graphcode-react-history-{}", Uuid::new_v4()))
    }

    #[test]
    fn saves_and_loads_versioned_navigation_history() {
        let directory = temporary_directory();
        save(
            &directory,
            NavigationHistory {
                version: HISTORY_VERSION,
                entries: vec![
                    NavigationRoute::Project {
                        project_path: "C:\\work\\graph".into(),
                        composite_path: vec!["parent".into()],
                        node_id: Some("child".into()),
                        terminal: true,
                    },
                    NavigationRoute::QuickChats,
                ],
                cursor: Some(1),
            },
        )
        .unwrap();

        let history = load(&directory).unwrap();
        assert_eq!(history.version, HISTORY_VERSION);
        assert_eq!(history.entries.len(), 2);
        assert_eq!(history.cursor, Some(1));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn clamps_a_cursor_from_an_older_or_hand_edited_file() {
        let directory = temporary_directory();
        fs::create_dir_all(&directory).unwrap();
        fs::write(
            directory.join(HISTORY_FILE),
            br#"{"version":1,"entries":[{"kind":"quickChats"}],"cursor":9}"#,
        )
        .unwrap();

        assert_eq!(load(&directory).unwrap().cursor, Some(0));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_unbounded_history() {
        let directory = temporary_directory();
        let error = save(
            &directory,
            NavigationHistory {
                version: HISTORY_VERSION,
                entries: (0..51).map(|_| NavigationRoute::QuickChats).collect(),
                cursor: Some(50),
            },
        )
        .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(!directory.join(HISTORY_FILE).exists());
    }
}
