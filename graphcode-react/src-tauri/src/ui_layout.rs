use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::{self, Write},
    path::Path,
};

use serde::{Deserialize, Serialize};
use uuid::Uuid;

const LAYOUT_FILE: &str = "ui-layout-v1.json";
const LAYOUT_VERSION: u32 = 1;
const MAX_LAYOUT_BYTES: usize = 1024 * 1024;
const MAX_VIEWPORT_VALUE: f64 = 10_000_000.0;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Viewport {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Viewport {
    fn validate(&self) -> io::Result<()> {
        if !self.x.is_finite()
            || !self.y.is_finite()
            || !self.width.is_finite()
            || !self.height.is_finite()
            || self.width <= 0.0
            || self.height <= 0.0
            || self.x.abs() > MAX_VIEWPORT_VALUE
            || self.y.abs() > MAX_VIEWPORT_VALUE
            || self.width > MAX_VIEWPORT_VALUE
            || self.height > MAX_VIEWPORT_VALUE
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "viewport coordinates must be finite and dimensions must be positive",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct Position {
    pub x: f64,
    pub y: f64,
}

impl Position {
    fn validate(&self) -> io::Result<()> {
        if !self.x.is_finite()
            || !self.y.is_finite()
            || self.x < 0.0
            || self.y < 0.0
            || self.x > MAX_VIEWPORT_VALUE
            || self.y > MAX_VIEWPORT_VALUE
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "node positions must be finite, non-negative, and bounded",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectLayout {
    pub views: BTreeMap<String, Viewport>,
    #[serde(default)]
    pub node_positions: BTreeMap<String, BTreeMap<String, Position>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LayoutState {
    pub version: u32,
    pub projects: BTreeMap<String, ProjectLayout>,
}

impl Default for LayoutState {
    fn default() -> Self {
        Self {
            version: LAYOUT_VERSION,
            projects: BTreeMap::new(),
        }
    }
}

pub fn load(state_directory: &Path) -> io::Result<LayoutState> {
    let raw = match fs::read(state_directory.join(LAYOUT_FILE)) {
        Ok(raw) => raw,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            return Ok(LayoutState::default());
        }
        Err(error) => return Err(error),
    };
    if raw.len() > MAX_LAYOUT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "UI layout file exceeds the 1 MiB client-state limit",
        ));
    }
    let state: LayoutState = serde_json::from_slice(&raw)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if state.version != LAYOUT_VERSION {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "unsupported UI layout version {}; expected {}",
                state.version, LAYOUT_VERSION
            ),
        ));
    }
    for (project_path, project) in &state.projects {
        validate_key(project_path, 32_768, "project path")?;
        for (view_key, viewport) in &project.views {
            validate_key(view_key, 8_192, "view key")?;
            viewport.validate()?;
        }
        for (view_key, positions) in &project.node_positions {
            validate_key(view_key, 8_192, "view key")?;
            for (node_id, position) in positions {
                validate_key(node_id, 8_192, "node ID")?;
                position.validate()?;
            }
        }
    }
    Ok(state)
}

pub fn save_node_positions(
    state_directory: &Path,
    project_path: String,
    view_key: String,
    positions: BTreeMap<String, Position>,
) -> io::Result<()> {
    validate_key(&project_path, 32_768, "project path")?;
    validate_key(&view_key, 8_192, "view key")?;
    for (node_id, position) in &positions {
        validate_key(node_id, 8_192, "node ID")?;
        position.validate()?;
    }
    let mut state = load(state_directory)?;
    let project = state.projects.entry(project_path).or_default();
    if positions.is_empty() {
        project.node_positions.remove(&view_key);
    } else {
        project.node_positions.insert(view_key, positions);
    }
    persist(state_directory, &state)
}

pub fn save_viewport(
    state_directory: &Path,
    project_path: String,
    view_key: String,
    viewport: Viewport,
) -> io::Result<()> {
    validate_key(&project_path, 32_768, "project path")?;
    validate_key(&view_key, 8_192, "view key")?;
    viewport.validate()?;
    let mut state = load(state_directory)?;
    state
        .projects
        .entry(project_path)
        .or_default()
        .views
        .insert(view_key, viewport);
    persist(state_directory, &state)
}

fn validate_key(value: &str, maximum: usize, label: &str) -> io::Result<()> {
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

fn persist(state_directory: &Path, state: &LayoutState) -> io::Result<()> {
    fs::create_dir_all(state_directory)?;
    let target = state_directory.join(LAYOUT_FILE);
    let temporary = state_directory.join(format!("{LAYOUT_FILE}.{}.tmp", Uuid::new_v4()));
    let encoded = serde_json::to_vec_pretty(state)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if encoded.len() > MAX_LAYOUT_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "UI layout state exceeds the 1 MiB client-state limit",
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
        std::env::temp_dir().join(format!("graphcode-react-layout-{}", Uuid::new_v4()))
    }

    #[test]
    fn saves_and_loads_versioned_project_viewports() {
        let directory = temporary_directory();
        save_viewport(
            &directory,
            "C:\\work\\graph".into(),
            "root".into(),
            Viewport {
                x: 10.0,
                y: 20.0,
                width: 900.0,
                height: 420.0,
            },
        )
        .unwrap();

        let state = load(&directory).unwrap();
        let viewport = &state.projects["C:\\work\\graph"].views["root"];
        assert_eq!(state.version, LAYOUT_VERSION);
        assert_eq!(viewport.x, 10.0);
        assert_eq!(viewport.width, 900.0);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn adds_node_positions_without_changing_the_layout_version() {
        let directory = temporary_directory();
        save_viewport(
            &directory,
            "C:\\work\\graph".into(),
            "root".into(),
            Viewport {
                x: 0.0,
                y: 0.0,
                width: 900.0,
                height: 420.0,
            },
        )
        .unwrap();
        save_node_positions(
            &directory,
            "C:\\work\\graph".into(),
            "root".into(),
            BTreeMap::from([("node-a".into(), Position { x: 120.0, y: 80.0 })]),
        )
        .unwrap();

        let state = load(&directory).unwrap();
        assert_eq!(state.version, LAYOUT_VERSION);
        assert_eq!(
            state.projects["C:\\work\\graph"].node_positions["root"]["node-a"].x,
            120.0
        );
        assert_eq!(state.projects["C:\\work\\graph"].views["root"].width, 900.0);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_invalid_viewports_without_writing_state() {
        let directory = temporary_directory();
        let error = save_viewport(
            &directory,
            "C:\\work\\graph".into(),
            "root".into(),
            Viewport {
                x: 0.0,
                y: 0.0,
                width: 0.0,
                height: 420.0,
            },
        )
        .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert!(!directory.join(LAYOUT_FILE).exists());
    }

    #[test]
    fn rejects_unsupported_layout_versions() {
        let directory = temporary_directory();
        fs::create_dir_all(&directory).unwrap();
        fs::write(
            directory.join(LAYOUT_FILE),
            br#"{"version":2,"projects":{}}"#,
        )
        .unwrap();

        let error = load(&directory).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        fs::remove_dir_all(directory).unwrap();
    }
}
