use std::{
    collections::{HashMap, VecDeque},
    path::{Path, PathBuf},
    process::Stdio,
    sync::{Arc, Mutex},
    time::Duration,
};

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use serde::Serialize;
use tauri::ipc::Channel;
use thiserror::Error;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    process::{Child, Command},
    sync::mpsc,
    time::timeout,
};
use uuid::Uuid;

use crate::endpoint;

const PROCESS_TIMEOUT: Duration = Duration::from_secs(5);
const OUTPUT_CHUNK_BYTES: usize = 16 * 1024;
const MAX_IN_FLIGHT_BYTES: usize = 512 * 1024;
const MAX_INPUT_BYTES: usize = 64 * 1024;
const MAX_HISTORY_BYTES: usize = 4 * 1024 * 1024;
const MAX_HISTORY_SCAN_BYTES: usize = 16 * 1024 * 1024;
const MIN_TERMINAL_DIMENSION: u16 = 2;
const MAX_TERMINAL_DIMENSION: u16 = 500;

#[derive(Debug, Error)]
pub enum TerminalError {
    #[error("invalid loop identifier")]
    InvalidNodeId,
    #[error("terminal dimensions must be between 2 and 500 cells")]
    InvalidDimensions,
    #[error("terminal input is not valid base64 or exceeds the 64 KiB command limit")]
    InputTooLarge,
    #[error("terminal history limit must be between 1 byte and 4 MiB")]
    InvalidHistoryLimit,
    #[error("zmx is unavailable at {0}")]
    ZmxUnavailable(String),
    #[error("the loop session is not running")]
    SessionUnavailable,
    #[error("a terminal is already open for this loop")]
    AlreadyOpen,
    #[error("the loop session is attached in another client")]
    AlreadyAttached,
    #[error("the loop session changed while the terminal was opening")]
    SessionChanged,
    #[error("terminal handle is no longer active")]
    NotOpen,
    #[error("failed to launch zmx: {0}")]
    Launch(String),
    #[error("zmx command timed out")]
    Timeout,
    #[error("zmx command failed: {0}")]
    Command(String),
    #[error("terminal stream failed: {0}")]
    Stream(String),
    #[error("terminal event channel closed")]
    ChannelClosed,
    #[error("terminal history exceeded the 16 MiB safety limit")]
    HistoryTooLarge,
}

#[derive(Debug, Serialize, Clone)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum TerminalEvent {
    Output {
        sequence: u64,
        byte_length: usize,
        data: String,
    },
    Error {
        message: String,
    },
    Exit {
        code: Option<i32>,
    },
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalOpenResult {
    pub handle: String,
    pub session_name: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalHistory {
    pub byte_length: usize,
    pub truncated: bool,
    pub data: String,
}

enum TerminalCommand {
    Write(Vec<u8>),
    Resize { columns: u16, rows: u16 },
    Acknowledge { sequence: u64 },
    Close,
}

struct ActiveTerminal {
    node_id: Uuid,
    sender: mpsc::Sender<TerminalCommand>,
}

#[derive(Clone, Default)]
pub struct TerminalManager {
    sessions: Arc<Mutex<HashMap<Uuid, ActiveTerminal>>>,
}

impl TerminalManager {
    pub async fn open(
        &self,
        node_id: &str,
        columns: u16,
        rows: u16,
        on_event: Channel<TerminalEvent>,
    ) -> Result<TerminalOpenResult, TerminalError> {
        validate_dimensions(columns, rows)?;
        let node_id = parse_node_id(node_id)?;
        let session_name = session_name(node_id);
        let handle = Uuid::new_v4();
        let (sender, receiver) = mpsc::channel(64);
        {
            let mut sessions = self
                .sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if sessions
                .values()
                .any(|terminal| terminal.node_id == node_id)
            {
                return Err(TerminalError::AlreadyOpen);
            } else {
                sessions.insert(
                    handle,
                    ActiveTerminal {
                        node_id,
                        sender: sender.clone(),
                    },
                );
            }
        }

        let prepared = prepare_attach(&session_name, columns, rows).await;
        let (zmx, child, stdin, stdout, stderr) = match prepared {
            Ok(prepared) => prepared,
            Err(error) => {
                self.remove(handle);
                return Err(error);
            }
        };
        let sessions = Arc::clone(&self.sessions);
        let actor_handle = handle;
        let actor_session_name = session_name.clone();
        tauri::async_runtime::spawn(async move {
            let result = run_terminal(
                &zmx,
                &actor_session_name,
                child,
                stdin,
                stdout,
                stderr,
                receiver,
                &on_event,
            )
            .await;
            if let Err(error) = result {
                let _ = on_event.send(TerminalEvent::Error {
                    message: error.to_string(),
                });
                let _ = on_event.send(TerminalEvent::Exit { code: None });
            }
            sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove(&actor_handle);
        });

        Ok(TerminalOpenResult {
            handle: handle.to_string(),
            session_name,
        })
    }

    pub async fn write(&self, handle: &str, data: &str) -> Result<(), TerminalError> {
        let bytes = BASE64
            .decode(data)
            .map_err(|_| TerminalError::InputTooLarge)?;
        if bytes.len() > MAX_INPUT_BYTES {
            return Err(TerminalError::InputTooLarge);
        }
        self.send(handle, TerminalCommand::Write(bytes)).await
    }

    pub async fn resize(&self, handle: &str, columns: u16, rows: u16) -> Result<(), TerminalError> {
        validate_dimensions(columns, rows)?;
        self.send(handle, TerminalCommand::Resize { columns, rows })
            .await
    }

    pub async fn acknowledge(&self, handle: &str, sequence: u64) -> Result<(), TerminalError> {
        self.send(handle, TerminalCommand::Acknowledge { sequence })
            .await
    }

    pub async fn close(&self, handle: &str) -> Result<(), TerminalError> {
        let handle = match Uuid::parse_str(handle) {
            Ok(handle) => handle,
            Err(_) => return Ok(()),
        };
        let sender = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&handle)
            .map(|terminal| terminal.sender);
        if let Some(sender) = sender {
            let _ = sender.send(TerminalCommand::Close).await;
        }
        Ok(())
    }

    async fn send(&self, handle: &str, command: TerminalCommand) -> Result<(), TerminalError> {
        let handle = Uuid::parse_str(handle).map_err(|_| TerminalError::NotOpen)?;
        let sender = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&handle)
            .map(|terminal| terminal.sender.clone())
            .ok_or(TerminalError::NotOpen)?;
        sender
            .send(command)
            .await
            .map_err(|_| TerminalError::NotOpen)
    }

    fn remove(&self, handle: Uuid) {
        self.sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&handle);
    }
}

pub async fn history(node_id: &str, max_bytes: usize) -> Result<TerminalHistory, TerminalError> {
    if max_bytes == 0 || max_bytes > MAX_HISTORY_BYTES {
        return Err(TerminalError::InvalidHistoryLimit);
    }
    let node_id = parse_node_id(node_id)?;
    let session_name = session_name(node_id);
    let zmx = zmx_binary()?;
    session_info(&zmx, &session_name).await?;
    let mut child = zmx_command(&zmx)
        .args(["history", &session_name, "--vt"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| TerminalError::Launch(error.to_string()))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| TerminalError::Launch("zmx history did not expose stdout".into()))?;
    let (bytes, truncated) =
        match timeout(PROCESS_TIMEOUT, read_bounded_tail(&mut stdout, max_bytes)).await {
            Ok(result) => result?,
            Err(_) => {
                let _ = child.kill().await;
                return Err(TerminalError::Timeout);
            }
        };
    let output = timeout(PROCESS_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| TerminalError::Timeout)?
        .map_err(|error| TerminalError::Command(error.to_string()))?;
    if !output.status.success() {
        return Err(TerminalError::Command(
            "terminal history is unavailable".into(),
        ));
    }
    Ok(TerminalHistory {
        byte_length: bytes.len(),
        truncated,
        data: BASE64.encode(bytes),
    })
}

type PreparedAttach = (
    PathBuf,
    Child,
    tokio::process::ChildStdin,
    tokio::process::ChildStdout,
    tokio::process::ChildStderr,
);

#[derive(Debug, PartialEq, Eq)]
struct SessionInfo {
    pid: u32,
    clients: u32,
    has_command: bool,
}

async fn prepare_attach(
    session_name: &str,
    columns: u16,
    rows: u16,
) -> Result<PreparedAttach, TerminalError> {
    let zmx = zmx_binary()?;
    let before = session_info(&zmx, session_name).await?;
    if before.clients != 0 {
        return Err(TerminalError::AlreadyAttached);
    }
    resize_session(&zmx, session_name, columns, rows, 0).await?;

    let mut child = zmx_command(&zmx)
        .args(["attach", session_name])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| TerminalError::Launch(error.to_string()))?;

    let attached = wait_for_attach(&zmx, session_name, before.pid, &mut child).await;
    if let Err(error) = attached {
        let _ = child.kill().await;
        if let Ok(after) = session_info(&zmx, session_name).await {
            if after.pid != before.pid && !after.has_command {
                let _ = run_command(&zmx, ["kill", session_name]).await;
            }
        }
        return Err(error);
    }

    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| TerminalError::Launch("zmx attach did not expose stdin".into()))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| TerminalError::Launch("zmx attach did not expose stdout".into()))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| TerminalError::Launch("zmx attach did not expose stderr".into()))?;
    Ok((zmx, child, stdin, stdout, stderr))
}

async fn wait_for_attach(
    zmx: &Path,
    session_name: &str,
    expected_pid: u32,
    child: &mut Child,
) -> Result<(), TerminalError> {
    for _ in 0..20 {
        if child
            .try_wait()
            .map_err(|error| TerminalError::Stream(error.to_string()))?
            .is_some()
        {
            return Err(TerminalError::SessionUnavailable);
        }
        if let Ok(info) = session_info(zmx, session_name).await {
            if info.pid != expected_pid {
                return Err(TerminalError::SessionChanged);
            }
            if info.clients == 1 {
                return Ok(());
            }
            if info.clients > 1 {
                return Err(TerminalError::AlreadyAttached);
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    Err(TerminalError::Timeout)
}

async fn run_terminal(
    zmx: &Path,
    session_name: &str,
    mut child: Child,
    mut stdin: tokio::process::ChildStdin,
    mut stdout: tokio::process::ChildStdout,
    mut stderr: tokio::process::ChildStderr,
    mut receiver: mpsc::Receiver<TerminalCommand>,
    on_event: &Channel<TerminalEvent>,
) -> Result<(), TerminalError> {
    let mut output_buffer = vec![0u8; OUTPUT_CHUNK_BYTES];
    let mut error_buffer = vec![0u8; 4096];
    let mut stderr_open = true;
    let mut output_window = OutputWindow::default();
    let (resize_result_tx, mut resize_result_rx) = mpsc::channel(1);
    let mut resize_in_flight = false;
    let mut pending_resize = None;
    loop {
        tokio::select! {
            read = stdout.read(&mut output_buffer), if output_window.can_read() => {
                let count = read.map_err(|error| TerminalError::Stream(error.to_string()))?;
                if count == 0 {
                    let status = child.wait().await.map_err(|error| TerminalError::Stream(error.to_string()))?;
                    on_event.send(TerminalEvent::Exit { code: status.code() })
                        .map_err(|_| TerminalError::ChannelClosed)?;
                    return Ok(());
                }
                let sequence = output_window.record(count);
                on_event
                    .send(TerminalEvent::Output {
                        sequence,
                        byte_length: count,
                        data: BASE64.encode(&output_buffer[..count]),
                    })
                    .map_err(|_| TerminalError::ChannelClosed)?;
            }
            read = stderr.read(&mut error_buffer), if stderr_open => {
                let count = read.map_err(|error| TerminalError::Stream(error.to_string()))?;
                if count == 0 {
                    stderr_open = false;
                } else {
                    let message = String::from_utf8_lossy(&error_buffer[..count])
                        .trim()
                        .to_owned();
                    if !message.is_empty() {
                        on_event
                            .send(TerminalEvent::Error { message })
                            .map_err(|_| TerminalError::ChannelClosed)?;
                    }
                }
            }
            command = receiver.recv() => {
                match command {
                    Some(TerminalCommand::Write(bytes)) => {
                        stdin.write_all(&bytes).await
                            .map_err(|error| TerminalError::Stream(error.to_string()))?;
                        stdin.flush().await
                            .map_err(|error| TerminalError::Stream(error.to_string()))?;
                    }
                    Some(TerminalCommand::Resize { columns, rows }) => {
                        pending_resize = Some((columns, rows));
                        if !resize_in_flight {
                            let (columns, rows) = pending_resize.take().expect("pending resize");
                            spawn_resize(
                                zmx.to_path_buf(),
                                session_name.to_owned(),
                                columns,
                                rows,
                                resize_result_tx.clone(),
                            );
                            resize_in_flight = true;
                        }
                    }
                    Some(TerminalCommand::Acknowledge { sequence }) => {
                        output_window.acknowledge(sequence);
                    }
                    Some(TerminalCommand::Close) | None => {
                        child.kill().await
                            .map_err(|error| TerminalError::Stream(error.to_string()))?;
                        let status = child.wait().await
                            .map_err(|error| TerminalError::Stream(error.to_string()))?;
                        on_event.send(TerminalEvent::Exit { code: status.code() })
                            .map_err(|_| TerminalError::ChannelClosed)?;
                        return Ok(());
                    }
                }
            }
            result = resize_result_rx.recv(), if resize_in_flight => {
                resize_in_flight = false;
                if let Some(Err(error)) = result {
                    on_event
                        .send(TerminalEvent::Error { message: error.to_string() })
                        .map_err(|_| TerminalError::ChannelClosed)?;
                }
                if let Some((columns, rows)) = pending_resize.take() {
                    spawn_resize(
                        zmx.to_path_buf(),
                        session_name.to_owned(),
                        columns,
                        rows,
                        resize_result_tx.clone(),
                    );
                    resize_in_flight = true;
                }
            }
        }
    }
}

#[derive(Default)]
struct OutputWindow {
    next_sequence: u64,
    in_flight_bytes: usize,
    in_flight: VecDeque<(u64, usize)>,
}

impl OutputWindow {
    fn can_read(&self) -> bool {
        self.in_flight_bytes < MAX_IN_FLIGHT_BYTES
    }

    fn record(&mut self, bytes: usize) -> u64 {
        self.next_sequence = self.next_sequence.saturating_add(1);
        self.in_flight_bytes = self.in_flight_bytes.saturating_add(bytes);
        self.in_flight.push_back((self.next_sequence, bytes));
        self.next_sequence
    }

    fn acknowledge(&mut self, sequence: u64) {
        while self
            .in_flight
            .front()
            .is_some_and(|(queued, _)| *queued <= sequence)
        {
            if let Some((_, bytes)) = self.in_flight.pop_front() {
                self.in_flight_bytes = self.in_flight_bytes.saturating_sub(bytes);
            }
        }
    }
}

fn spawn_resize(
    zmx: PathBuf,
    session_name: String,
    columns: u16,
    rows: u16,
    result: mpsc::Sender<Result<(), TerminalError>>,
) {
    tauri::async_runtime::spawn(async move {
        let outcome = resize_session(&zmx, &session_name, columns, rows, 1).await;
        let _ = result.send(outcome).await;
    });
}

fn parse_node_id(node_id: &str) -> Result<Uuid, TerminalError> {
    Uuid::parse_str(node_id).map_err(|_| TerminalError::InvalidNodeId)
}

fn session_name(node_id: Uuid) -> String {
    format!(
        "graphcode-{}",
        node_id.hyphenated().to_string().to_uppercase()
    )
}

fn validate_dimensions(columns: u16, rows: u16) -> Result<(), TerminalError> {
    if !(MIN_TERMINAL_DIMENSION..=MAX_TERMINAL_DIMENSION).contains(&columns)
        || !(MIN_TERMINAL_DIMENSION..=MAX_TERMINAL_DIMENSION).contains(&rows)
    {
        return Err(TerminalError::InvalidDimensions);
    }
    Ok(())
}

fn zmx_binary() -> Result<PathBuf, TerminalError> {
    let binary = endpoint::configured_support_directory()
        .map_err(|error| TerminalError::ZmxUnavailable(error.to_string()))?
        .join("bin")
        .join(if cfg!(windows) { "zmx.exe" } else { "zmx" });
    if !binary.is_file() {
        return Err(TerminalError::ZmxUnavailable(binary.display().to_string()));
    }
    Ok(binary)
}

async fn session_info(zmx: &Path, session_name: &str) -> Result<SessionInfo, TerminalError> {
    let output = run_command(zmx, ["info", session_name]).await?;
    if !output.status.success() {
        return Err(TerminalError::SessionUnavailable);
    }
    parse_session_info(&String::from_utf8_lossy(&output.stdout))
        .ok_or(TerminalError::SessionUnavailable)
}

fn parse_session_info(output: &str) -> Option<SessionInfo> {
    let mut pid = None;
    let mut clients = None;
    let mut has_command = false;
    for field in output.trim().split('\t').skip(1) {
        let (key, value) = field.split_once('=')?;
        match key {
            "pid" => pid = value.parse().ok(),
            "clients" => clients = value.parse().ok(),
            "cmd" => has_command = !value.is_empty(),
            _ => {}
        }
    }
    Some(SessionInfo {
        pid: pid?,
        clients: clients?,
        has_command,
    })
}

async fn resize_session(
    zmx: &Path,
    session_name: &str,
    columns: u16,
    rows: u16,
    expected_clients: u32,
) -> Result<(), TerminalError> {
    validate_dimensions(columns, rows)?;
    if session_info(zmx, session_name).await?.clients != expected_clients {
        return Err(TerminalError::AlreadyAttached);
    }
    let columns = columns.to_string();
    let rows = rows.to_string();
    let output = run_command(zmx, ["resize", session_name, &columns, &rows]).await?;
    if output.status.success() {
        return Ok(());
    }
    Err(TerminalError::Command("terminal resize failed".into()))
}

async fn run_command<const N: usize>(
    zmx: &Path,
    arguments: [&str; N],
) -> Result<std::process::Output, TerminalError> {
    timeout(
        PROCESS_TIMEOUT,
        zmx_command(zmx)
            .args(arguments)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| TerminalError::Timeout)?
    .map_err(|error| TerminalError::Launch(error.to_string()))
}

fn zmx_command(zmx: &Path) -> Command {
    let mut command = Command::new(zmx);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.as_std_mut().creation_flags(0x0800_0000);
    }
    command
}

async fn read_bounded_tail<R: AsyncRead + Unpin>(
    reader: &mut R,
    limit: usize,
) -> Result<(Vec<u8>, bool), TerminalError> {
    let mut output = Vec::with_capacity(limit.min(OUTPUT_CHUNK_BYTES));
    let mut buffer = [0u8; OUTPUT_CHUNK_BYTES];
    let mut total = 0usize;
    let mut truncated = false;
    loop {
        let count = reader
            .read(&mut buffer)
            .await
            .map_err(|error| TerminalError::Stream(error.to_string()))?;
        if count == 0 {
            return Ok((output, truncated));
        }
        total = total.saturating_add(count);
        if total > MAX_HISTORY_SCAN_BYTES {
            return Err(TerminalError::HistoryTooLarge);
        }
        if count >= limit {
            output.clear();
            output.extend_from_slice(&buffer[count - limit..count]);
            truncated = true;
        } else if output.len() > limit - count {
            let overflow = output.len() + count - limit;
            output.drain(..overflow);
            output.extend_from_slice(&buffer[..count]);
            truncated = true;
        } else {
            output.extend_from_slice(&buffer[..count]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[test]
    fn session_names_use_swift_uuid_format() {
        let id = Uuid::parse_str("2e527087-b363-48b9-883b-ffd255f01675").unwrap();
        assert_eq!(
            session_name(id),
            "graphcode-2E527087-B363-48B9-883B-FFD255F01675"
        );
    }

    #[test]
    fn dimensions_are_bounded() {
        assert!(validate_dimensions(120, 40).is_ok());
        assert!(validate_dimensions(1, 40).is_err());
        assert!(validate_dimensions(120, 501).is_err());
    }

    #[test]
    fn session_info_reads_identity_and_attach_count() {
        assert_eq!(
            parse_session_info(
                "graphcode-ABC\tclients=1\tpid=42\tcmd=copilot --resume id\tcwd=C:\\work\n"
            ),
            Some(SessionInfo {
                pid: 42,
                clients: 1,
                has_command: true,
            })
        );
        assert!(parse_session_info("graphcode-ABC\tclients=1").is_none());
    }

    #[test]
    fn output_window_releases_acknowledged_bytes() {
        let mut window = OutputWindow::default();
        let first = window.record(200_000);
        let second = window.record(350_000);
        assert!(!window.can_read());
        window.acknowledge(first);
        assert!(window.can_read());
        assert_eq!(window.in_flight_bytes, 350_000);
        window.acknowledge(second);
        assert_eq!(window.in_flight_bytes, 0);
    }

    #[tokio::test]
    async fn bounded_reader_keeps_the_history_tail() {
        let (mut writer, mut reader) = tokio::io::duplex(32);
        writer.write_all(b"12345").await.unwrap();
        drop(writer);
        let (bytes, truncated) = read_bounded_tail(&mut reader, 4).await.unwrap();
        assert_eq!(bytes, b"2345");
        assert!(truncated);
    }
}
