mod connection;
mod endpoint;
mod protocol;
mod transport;

use std::sync::Mutex;

use connection::ConnectionHandle;
use endpoint::discover;
use serde::Serialize;
use serde_json::Value;
use tauri::{Manager, State};
use thiserror::Error;

#[derive(Default)]
struct BridgeState {
    connection: Mutex<Option<ConnectionHandle>>,
}

#[derive(Debug, Error)]
enum BridgeError {
    #[error(transparent)]
    Endpoint(#[from] endpoint::EndpointError),
    #[error("failed to resolve Tauri application data directory: {0}")]
    AppData(String),
    #[error("failed to load persistent daemon client identity: {0}")]
    ClientIdentity(String),
    #[error("failed to load persistent daemon replay state: {0}")]
    ReplayState(String),
    #[error("daemon connection has not been started")]
    NotStarted,
    #[error(transparent)]
    Connection(#[from] connection::ConnectionError),
}

impl Serialize for BridgeError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConnectionStart {
    endpoint: String,
    client_id: String,
    resume_from: Option<u64>,
}

#[tauri::command]
async fn start_daemon_connection(
    app: tauri::AppHandle,
    state: State<'_, BridgeState>,
) -> Result<ConnectionStart, BridgeError> {
    let endpoint = discover()?;
    let endpoint_name = endpoint.display_name();
    let state_directory = app
        .path()
        .app_data_dir()
        .map_err(|error| BridgeError::AppData(error.to_string()))?;
    let client_id = connection::load_or_create_client_id(&state_directory)
        .map_err(|error| BridgeError::ClientIdentity(error.to_string()))?;
    let resume_from = connection::load_replay_cursor(&state_directory)
        .map_err(|error| BridgeError::ReplayState(error.to_string()))?;

    let mut guard = state
        .connection
        .lock()
        .expect("bridge state mutex poisoned");
    if guard.is_none() {
        *guard = Some(connection::spawn(
            app,
            endpoint,
            state_directory,
            client_id,
            resume_from,
        ));
    }

    Ok(ConnectionStart {
        endpoint: endpoint_name,
        client_id: client_id.to_string(),
        resume_from,
    })
}

#[tauri::command]
async fn send_daemon_command(
    state: State<'_, BridgeState>,
    command: Value,
) -> Result<Value, BridgeError> {
    let connection = state
        .connection
        .lock()
        .expect("bridge state mutex poisoned")
        .clone()
        .ok_or(BridgeError::NotStarted)?;
    connection.request(command).await.map_err(Into::into)
}

#[tauri::command]
async fn acknowledge_daemon_sequence(
    state: State<'_, BridgeState>,
    sequence: u64,
) -> Result<(), BridgeError> {
    let connection = state
        .connection
        .lock()
        .expect("bridge state mutex poisoned")
        .clone()
        .ok_or(BridgeError::NotStarted)?;
    connection.acknowledge(sequence).await.map_err(Into::into)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(BridgeState::default())
        .invoke_handler(tauri::generate_handler![
            start_daemon_connection,
            send_daemon_command,
            acknowledge_daemon_sequence
        ])
        .run(tauri::generate_context!())
        .expect("failed to run GraphCode React");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{negotiate, read_frame, request, write_frame};
    use serde_json::json;
    use tokio::time::{timeout, Duration};
    use uuid::Uuid;

    fn response_matches_request(frame: &Value, request_id: Uuid) -> bool {
        frame
            .get("requestID")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            == Some(request_id)
    }

    #[test]
    fn request_correlation_accepts_swift_uppercase_uuid_encoding() {
        let request_id = Uuid::parse_str("69ecfae8-e0d0-48f3-ae5c-bba390bd0b30").unwrap();
        let frame = json!({
            "version": 2,
            "kind": "response",
            "requestID": "69ECFAE8-E0D0-48F3-AE5C-BBA390BD0B30",
            "success": true
        });

        assert!(response_matches_request(&frame, request_id));
    }

    #[tokio::test]
    async fn live_daemon_lists_recent_projects_when_requested() {
        if std::env::var_os("GRAPHCODE_RUN_LIVE_DAEMON_TEST").is_none() {
            return;
        }

        let endpoint = discover().unwrap();
        let mut stream = transport::connect(&endpoint).await.unwrap();
        negotiate(&mut stream).await.unwrap();
        let (request_id, request) = request(json!({ "listRecentProjects": {} }));
        write_frame(&mut stream, &request).await.unwrap();
        let response = timeout(Duration::from_secs(15), read_frame(&mut stream))
            .await
            .expect("live daemon response timed out")
            .unwrap();

        assert!(response_matches_request(&response, request_id));
        assert_eq!(
            response.get("kind"),
            Some(&Value::String("response".into()))
        );
        assert!(response["event"].get("recentProjectsListed").is_some());
    }
}
