use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use thiserror::Error;

use crate::connection::{ConnectionError, ConnectionHandle};

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error(transparent)]
    Connection(#[from] ConnectionError),
    #[error("graphcoded returned an invalid settings response")]
    InvalidResponse,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsSnapshot {
    pub settings: Value,
    pub revision: String,
    pub exists: bool,
    pub support_directory: String,
    pub file_path: String,
    pub fields: Vec<SettingsFieldContract>,
    #[serde(default)]
    pub daemon_heartbeat_enabled: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsFieldContract {
    pub field: String,
    pub timing: String,
}

pub async fn load(connection: &ConnectionHandle) -> Result<SettingsSnapshot, SettingsError> {
    let frame = connection.request(json!({ "loadSettings": {} })).await?;
    snapshot_from_frame(&frame)
}

pub async fn set_daemon_heartbeat(
    connection: &ConnectionHandle,
    expected_revision: &str,
    mut settings: Value,
    enabled: bool,
) -> Result<SettingsSnapshot, SettingsError> {
    let object = settings
        .as_object_mut()
        .ok_or(SettingsError::InvalidResponse)?;
    object.insert("daemonHeartbeatEnabled".into(), Value::Bool(enabled));
    let frame = connection
        .request(json!({
            "updateSettings": {
                "expectedRevision": expected_revision,
                "settings": settings
            }
        }))
        .await?;
    snapshot_from_frame(&frame)
}

fn snapshot_from_frame(frame: &Value) -> Result<SettingsSnapshot, SettingsError> {
    let value = frame
        .pointer("/event/settingsChanged/_0")
        .or_else(|| frame.pointer("/event/settingsChanged"))
        .ok_or(SettingsError::InvalidResponse)?;
    let mut snapshot: SettingsSnapshot =
        serde_json::from_value(value.clone()).map_err(|_| SettingsError::InvalidResponse)?;
    snapshot.daemon_heartbeat_enabled = snapshot
        .settings
        .get("daemonHeartbeatEnabled")
        .and_then(Value::as_bool)
        .ok_or(SettingsError::InvalidResponse)?;
    Ok(snapshot)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_the_correlated_swift_settings_shape() {
        let frame = json!({
            "event": {
                "settingsChanged": {
                    "_0": {
                        "settings": { "daemonHeartbeatEnabled": false },
                        "revision": "abc",
                        "exists": true,
                        "supportDirectory": "C:\\fixture",
                        "filePath": "C:\\fixture\\settings.json",
                        "fields": [
                            { "field": "daemonHeartbeatEnabled", "timing": "live" }
                        ]
                    }
                }
            }
        });

        let snapshot = snapshot_from_frame(&frame).unwrap();
        assert!(!snapshot.daemon_heartbeat_enabled);
        assert_eq!(snapshot.revision, "abc");
        assert_eq!(snapshot.fields[0].timing, "live");
    }
}
