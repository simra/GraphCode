mod endpoint;
mod protocol;
mod transport;

use endpoint::discover;
use protocol::{negotiate, read_frame, request, write_frame};
use serde::Serialize;
use serde_json::{json, Value};
use thiserror::Error;
use tokio::time::{timeout, Duration};

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
            let is_recent_response =
                frame.get("requestID") == Some(&Value::String(recent_id.to_string()));
            frames.push(frame);
            if is_recent_response {
                return Ok::<(), protocol::ProtocolError>(());
            }
        }
    };
    timeout(Duration::from_secs(5), collect)
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
