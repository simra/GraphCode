use serde::{ser::SerializeStruct, Deserialize, Serialize};
use serde_json::{json, Value};
use thiserror::Error;

use crate::connection::{ConnectionError, ConnectionHandle};

#[derive(Debug, Error)]
pub enum SettingsError {
    #[error("daemon connection has not been started")]
    NotStarted,
    #[error(transparent)]
    Connection(ConnectionError),
    #[error("graphcoded returned an invalid settings response")]
    InvalidResponse,
}

impl From<ConnectionError> for SettingsError {
    fn from(error: ConnectionError) -> Self {
        Self::Connection(error)
    }
}

impl SettingsError {
    fn code(&self) -> &str {
        match self {
            Self::NotStarted => "settingsUnavailable",
            Self::Connection(ConnectionError::Daemon { code, .. }) => code,
            Self::Connection(_) => "settingsUnavailable",
            Self::InvalidResponse => "settingsInvalidResponse",
        }
    }
}

impl Serialize for SettingsError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        let mut state = serializer.serialize_struct("SettingsError", 2)?;
        state.serialize_field("code", self.code())?;
        state.serialize_field("message", &self.to_string())?;
        state.end()
    }
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

pub async fn update(
    connection: &ConnectionHandle,
    expected_revision: &str,
    settings: Value,
) -> Result<SettingsSnapshot, SettingsError> {
    if !settings.is_object() {
        return Err(SettingsError::InvalidResponse);
    }
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
    let snapshot: SettingsSnapshot =
        serde_json::from_value(value.clone()).map_err(|_| SettingsError::InvalidResponse)?;
    if !snapshot.settings.is_object() {
        return Err(SettingsError::InvalidResponse);
    }
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
        assert_eq!(snapshot.settings["daemonHeartbeatEnabled"], false);
        assert_eq!(snapshot.revision, "abc");
        assert_eq!(snapshot.fields[0].timing, "live");
    }

    #[test]
    fn serializes_daemon_error_codes_for_conflict_recovery() {
        let error = SettingsError::Connection(ConnectionError::Daemon {
            code: "settingsConflict".into(),
            message: "reload".into(),
        });
        assert_eq!(
            serde_json::to_value(error).unwrap(),
            json!({
                "code": "settingsConflict",
                "message": "graphcoded refused the command (settingsConflict): reload"
            })
        );
    }
}
