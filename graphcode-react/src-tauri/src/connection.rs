use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};
use thiserror::Error;
use tokio::{
    io::WriteHalf,
    sync::{mpsc, oneshot},
    time::{interval, sleep, Instant},
};
use uuid::Uuid;

use crate::{
    endpoint::DaemonEndpoint,
    protocol::{self, negotiate_with, read_frame, request, write_frame},
    transport::{self, BoxedDaemonStream},
};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(15);
const MIN_RECONNECT_DELAY: Duration = Duration::from_millis(100);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(4);

#[derive(Debug, Error)]
pub enum ConnectionError {
    #[error("graphcoded is not connected")]
    Unavailable,
    #[error("graphcoded disconnected before the command outcome was known")]
    OutcomeUnknown,
    #[error("graphcoded command timed out")]
    CommandTimeout,
    #[error("graphcoded refused the command ({code}): {message}")]
    Daemon { code: String, message: String },
    #[error("daemon connection actor stopped")]
    ActorStopped,
    #[error("failed to persist daemon replay state: {0}")]
    ReplayState(String),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionStatus {
    pub phase: &'static str,
    pub endpoint: String,
    pub attempt: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resume_from: Option<u64>,
}

pub enum ActorMessage {
    Request {
        command: Value,
        response: oneshot::Sender<Result<Value, ConnectionError>>,
    },
    Acknowledge {
        sequence: u64,
        response: oneshot::Sender<Result<(), ConnectionError>>,
    },
}

#[derive(Clone)]
pub struct ConnectionHandle {
    sender: mpsc::Sender<ActorMessage>,
}

impl ConnectionHandle {
    pub async fn request(&self, command: Value) -> Result<Value, ConnectionError> {
        let (response_tx, response_rx) = oneshot::channel();
        self.sender
            .send(ActorMessage::Request {
                command,
                response: response_tx,
            })
            .await
            .map_err(|_| ConnectionError::ActorStopped)?;
        response_rx
            .await
            .map_err(|_| ConnectionError::ActorStopped)?
    }

    pub async fn acknowledge(&self, sequence: u64) -> Result<(), ConnectionError> {
        let (response_tx, response_rx) = oneshot::channel();
        self.sender
            .send(ActorMessage::Acknowledge {
                sequence,
                response: response_tx,
            })
            .await
            .map_err(|_| ConnectionError::ActorStopped)?;
        response_rx
            .await
            .map_err(|_| ConnectionError::ActorStopped)?
    }
}

struct PendingRequest {
    started_at: Instant,
    response: oneshot::Sender<Result<Value, ConnectionError>>,
}

#[derive(Debug, Error)]
enum SessionError {
    #[error(transparent)]
    Transport(#[from] transport::TransportError),
    #[error(transparent)]
    Protocol(#[from] protocol::ProtocolError),
}

pub fn spawn(
    app: AppHandle,
    endpoint: DaemonEndpoint,
    state_directory: PathBuf,
    client_id: Uuid,
    resume_from: Option<u64>,
) -> ConnectionHandle {
    let (sender, receiver) = mpsc::channel(64);
    tauri::async_runtime::spawn(run_actor(
        app,
        endpoint,
        state_directory,
        client_id,
        resume_from,
        receiver,
    ));
    ConnectionHandle { sender }
}

async fn run_actor(
    app: AppHandle,
    endpoint: DaemonEndpoint,
    state_directory: PathBuf,
    client_id: Uuid,
    mut resume_from: Option<u64>,
    mut receiver: mpsc::Receiver<ActorMessage>,
) {
    let endpoint_name = endpoint.display_name();
    let mut attempt = 0u32;
    let mut has_connected = false;

    loop {
        attempt = attempt.saturating_add(1);
        emit_status(
            &app,
            ConnectionStatus {
                phase: if attempt == 1 && !has_connected {
                    "connecting"
                } else {
                    "reconnecting"
                },
                endpoint: endpoint_name.clone(),
                attempt,
                message: None,
                resume_from,
            },
        );

        match connect_session(&endpoint, client_id, resume_from).await {
            Ok(stream) => {
                attempt = 0;
                has_connected = true;
                emit_status(
                    &app,
                    ConnectionStatus {
                        phase: "connected",
                        endpoint: endpoint_name.clone(),
                        attempt,
                        message: None,
                        resume_from,
                    },
                );
                let disconnect_reason = run_connected(
                    &app,
                    stream,
                    &state_directory,
                    &mut resume_from,
                    &mut receiver,
                )
                .await;
                emit_status(
                    &app,
                    ConnectionStatus {
                        phase: "reconnecting",
                        endpoint: endpoint_name.clone(),
                        attempt: 1,
                        message: Some(disconnect_reason),
                        resume_from,
                    },
                );
            }
            Err(SessionError::Protocol(protocol::ProtocolError::ReplayUnavailable(reason))) => {
                resume_from = None;
                let persistence_error = persist_replay_cursor(&state_directory, None)
                    .err()
                    .map(|error| format!("; clearing the saved cursor also failed: {error}"));
                emit_status(
                    &app,
                    ConnectionStatus {
                        phase: "resyncing",
                        endpoint: endpoint_name.clone(),
                        attempt,
                        message: Some(format!(
                            "Saved replay cursor was unavailable ({reason}); requesting fresh snapshots{}",
                            persistence_error.as_deref().unwrap_or("")
                        )),
                        resume_from: None,
                    },
                );
                continue;
            }
            Err(error) => {
                emit_status(
                    &app,
                    ConnectionStatus {
                        phase: "reconnecting",
                        endpoint: endpoint_name.clone(),
                        attempt,
                        message: Some(error.to_string()),
                        resume_from,
                    },
                );
            }
        }

        let delay = reconnect_delay(attempt.max(1));
        tokio::select! {
            _ = sleep(delay) => {}
            message = receiver.recv() => {
                match message {
                    Some(ActorMessage::Request { response, .. }) => {
                        let _ = response.send(Err(ConnectionError::Unavailable));
                    }
                    Some(ActorMessage::Acknowledge { sequence, response }) => {
                        let _ = response.send(acknowledge_sequence(
                            &state_directory,
                            &mut resume_from,
                            sequence,
                        ));
                    }
                    None => return,
                }
            }
        }
    }
}

async fn connect_session(
    endpoint: &DaemonEndpoint,
    client_id: Uuid,
    resume_from: Option<u64>,
) -> Result<BoxedDaemonStream, SessionError> {
    let mut stream = transport::connect(endpoint).await?;
    negotiate_with(&mut stream, client_id, resume_from).await?;
    Ok(stream)
}

async fn run_connected(
    app: &AppHandle,
    stream: BoxedDaemonStream,
    state_directory: &Path,
    resume_from: &mut Option<u64>,
    receiver: &mut mpsc::Receiver<ActorMessage>,
) -> String {
    let (mut reader, mut writer) = tokio::io::split(stream);
    if let Err(error) = send_bootstrap_requests(&mut writer).await {
        return error.to_string();
    }

    let mut pending = HashMap::<Uuid, PendingRequest>::new();
    let mut timeout_check = interval(Duration::from_secs(1));

    let reason = loop {
        tokio::select! {
            frame = read_frame(&mut reader) => {
                match frame {
                    Ok(frame) => route_frame(app, frame, &mut pending),
                    Err(error) => break error.to_string(),
                }
            }
            message = receiver.recv() => {
                match message {
                    Some(ActorMessage::Request { command, response }) => {
                        let (request_id, frame) = request(command);
                        if let Err(error) = write_frame(&mut writer, &frame).await {
                            let _ = response.send(Err(ConnectionError::OutcomeUnknown));
                            break error.to_string();
                        }
                        pending.insert(request_id, PendingRequest {
                            started_at: Instant::now(),
                            response,
                        });
                    }
                    Some(ActorMessage::Acknowledge { sequence, response }) => {
                        let _ = response.send(acknowledge_sequence(
                            state_directory,
                            resume_from,
                            sequence,
                        ));
                    }
                    None => break "connection owner stopped".to_owned(),
                }
            }
            _ = timeout_check.tick() => {
                expire_requests(&mut pending);
            }
        }
    };

    for (_, pending_request) in pending {
        let _ = pending_request
            .response
            .send(Err(ConnectionError::OutcomeUnknown));
    }
    reason
}

async fn send_bootstrap_requests(
    writer: &mut WriteHalf<BoxedDaemonStream>,
) -> Result<(), protocol::ProtocolError> {
    for command in [
        json!({ "announce": { "capabilities": ["nodesChanged"] } }),
        json!({ "restoreOpenProjects": {} }),
        json!({ "openGlobalGraph": {} }),
        json!({ "listRecentProjects": {} }),
        json!({ "listQuickChats": {} }),
    ] {
        let (_, frame) = request(command);
        write_frame(writer, &frame).await?;
    }
    Ok(())
}

fn route_frame(app: &AppHandle, frame: Value, pending: &mut HashMap<Uuid, PendingRequest>) {
    resolve_pending(&frame, pending);
    let _ = app.emit("daemon://frame", frame);
}

fn resolve_pending(frame: &Value, pending: &mut HashMap<Uuid, PendingRequest>) {
    let request_id = frame
        .get("requestID")
        .and_then(Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok());

    if let Some(request_id) = request_id {
        if let Some(pending_request) = pending.remove(&request_id) {
            let result = if frame.get("kind") == Some(&Value::String("error".into())) {
                Err(ConnectionError::Daemon {
                    code: frame
                        .pointer("/error/code")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown")
                        .to_owned(),
                    message: frame
                        .pointer("/error/message")
                        .and_then(Value::as_str)
                        .unwrap_or("graphcoded rejected the command")
                        .to_owned(),
                })
            } else {
                Ok(frame.clone())
            };
            let _ = pending_request.response.send(result);
        }
    }
}

fn expire_requests(pending: &mut HashMap<Uuid, PendingRequest>) {
    let expired = pending
        .iter()
        .filter_map(|(request_id, request)| {
            (request.started_at.elapsed() >= COMMAND_TIMEOUT).then_some(*request_id)
        })
        .collect::<Vec<_>>();
    for request_id in expired {
        if let Some(request) = pending.remove(&request_id) {
            let _ = request.response.send(Err(ConnectionError::CommandTimeout));
        }
    }
}

fn acknowledge_sequence(
    state_directory: &Path,
    resume_from: &mut Option<u64>,
    sequence: u64,
) -> Result<(), ConnectionError> {
    if resume_from.is_some_and(|current| current >= sequence) {
        return Ok(());
    }
    persist_replay_cursor(state_directory, Some(sequence))
        .map_err(|error| ConnectionError::ReplayState(error.to_string()))?;
    *resume_from = Some(sequence);
    Ok(())
}

fn emit_status(app: &AppHandle, status: ConnectionStatus) {
    let _ = app.emit("daemon://status", status);
}

fn reconnect_delay(attempt: u32) -> Duration {
    let exponent = attempt.saturating_sub(1).min(5);
    let cap = MIN_RECONNECT_DELAY
        .saturating_mul(1u32 << exponent)
        .min(MAX_RECONNECT_DELAY);
    let upper_ms = u64::try_from(cap.as_millis()).unwrap_or(u64::MAX);
    Duration::from_millis(fastrand::u64(0..=upper_ms))
}

pub fn load_or_create_client_id(state_directory: &Path) -> std::io::Result<Uuid> {
    fs::create_dir_all(state_directory)?;
    let path = state_directory.join("daemon-client-id");
    if let Ok(raw) = fs::read_to_string(&path) {
        if let Ok(client_id) = Uuid::parse_str(raw.trim()) {
            return Ok(client_id);
        }
    }
    let client_id = Uuid::new_v4();
    fs::write(path, client_id.to_string())?;
    Ok(client_id)
}

pub fn load_replay_cursor(state_directory: &Path) -> std::io::Result<Option<u64>> {
    match fs::read_to_string(state_directory.join("daemon-replay-sequence")) {
        Ok(raw) => raw
            .trim()
            .parse()
            .map(Some)
            .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidData, error)),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn persist_replay_cursor(state_directory: &Path, sequence: Option<u64>) -> std::io::Result<()> {
    fs::create_dir_all(state_directory)?;
    let path = state_directory.join("daemon-replay-sequence");
    match sequence {
        Some(sequence) => fs::write(path, sequence.to_string()),
        None => match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stable_client_id_is_reused() {
        let directory = std::env::temp_dir().join(format!("graphcode-react-{}", Uuid::new_v4()));
        let first = load_or_create_client_id(&directory).unwrap();
        let second = load_or_create_client_id(&directory).unwrap();
        fs::remove_dir_all(directory).unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn replay_cursor_only_moves_forward() {
        let directory = std::env::temp_dir().join(format!("graphcode-react-{}", Uuid::new_v4()));
        let mut cursor = Some(7);
        acknowledge_sequence(&directory, &mut cursor, 6).unwrap();
        acknowledge_sequence(&directory, &mut cursor, 9).unwrap();
        assert_eq!(cursor, Some(9));
        assert_eq!(load_replay_cursor(&directory).unwrap(), Some(9));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn reconnect_delay_stays_within_exponential_cap() {
        for attempt in 1..20 {
            assert!(reconnect_delay(attempt) <= MAX_RECONNECT_DELAY);
        }
    }

    #[tokio::test]
    async fn uppercase_response_ids_correlate() {
        let request_id = Uuid::parse_str("69ecfae8-e0d0-48f3-ae5c-bba390bd0b30").unwrap();
        let (response_tx, response_rx) = oneshot::channel();
        let mut pending = HashMap::from([(
            request_id,
            PendingRequest {
                started_at: Instant::now(),
                response: response_tx,
            },
        )]);
        let frame = json!({
            "version": 2,
            "kind": "response",
            "requestID": "69ECFAE8-E0D0-48F3-AE5C-BBA390BD0B30",
            "success": true
        });

        resolve_pending(&frame, &mut pending);

        assert_eq!(response_rx.await.unwrap().unwrap()["success"], true);
    }

    #[tokio::test]
    async fn correlated_daemon_errors_are_explicit() {
        let request_id = Uuid::new_v4();
        let (response_tx, response_rx) = oneshot::channel();
        let mut pending = HashMap::from([(
            request_id,
            PendingRequest {
                started_at: Instant::now(),
                response: response_tx,
            },
        )]);
        let frame = json!({
            "version": 2,
            "kind": "error",
            "requestID": request_id,
            "error": {
                "code": "invalidCommand",
                "message": "not allowed"
            }
        });

        resolve_pending(&frame, &mut pending);

        assert!(matches!(
            response_rx.await.unwrap(),
            Err(ConnectionError::Daemon { code, message })
                if code == "invalidCommand" && message == "not allowed"
        ));
    }
}
