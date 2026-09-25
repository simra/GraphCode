mod endpoint;
mod protocol;
mod transport;

use endpoint::discover;
use protocol::{negotiate, read_frame, request, write_frame};
use serde::Serialize;
use serde_json::{json, Value};
use thiserror::Error;
use tokio::time::{timeout, Duration};
use uuid::Uuid;

#[derive(Debug, Error)]
enum BridgeError {
    #[error(transparent)]
    Endpoint(#[from] endpoint::EndpointError),
    #[error(transparent)]
    Transport(#[from] transport::TransportError),
    #[error(transparent)]
    Protocol(#[from] protocol::ProtocolError),
    #[error("graphcoded did not answer the initial state request before the deadline")]
    InitialStateTimeout,
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
struct InitialDaemonState {
    endpoint: String,
    frames: Vec<Value>,
}

fn response_matches_request(frame: &Value, request_id: Uuid) -> bool {
    frame
        .get("requestID")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
        == Some(request_id)
}

#[tauri::command]
async fn connect_initial_daemon_state() -> Result<InitialDaemonState, BridgeError> {
    let endpoint = discover()?;
    let endpoint_name = endpoint.display_name();
    let mut stream = transport::connect(&endpoint).await?;
    negotiate(&mut stream).await?;

    let (_, announce) = request(json!({
        "announce": { "capabilities": ["nodesChanged"] }
    }));
    write_frame(&mut stream, &announce).await?;
    let (_, restore) = request(json!({ "restoreOpenProjects": {} }));
    write_frame(&mut stream, &restore).await?;
    let (recent_id, recent) = request(json!({ "listRecentProjects": {} }));
    write_frame(&mut stream, &recent).await?;

    let mut frames = Vec::new();
    let collect = async {
        loop {
            let frame = read_frame(&mut stream).await?;
            let is_recent_response = response_matches_request(&frame, recent_id);
            frames.push(frame);
            if is_recent_response {
                return Ok::<(), protocol::ProtocolError>(());
            }
        }
    };
    timeout(Duration::from_secs(15), collect)
        .await
        .map_err(|_| BridgeError::InitialStateTimeout)??;

    Ok(InitialDaemonState {
        endpoint: endpoint_name,
        frames,
    })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![connect_initial_daemon_state])
        .run(tauri::generate_context!())
        .expect("failed to run GraphCode React");
}

#[cfg(test)]
mod tests {
    use super::*;

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
