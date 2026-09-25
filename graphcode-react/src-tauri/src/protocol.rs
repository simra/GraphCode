use serde_json::{json, Value};
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::time::{timeout, Duration};
use uuid::Uuid;

const V2_MAX_PAYLOAD: usize = 1_048_576;
const FRAME_TIMEOUT: Duration = Duration::from_secs(2);

#[derive(Debug, Error)]
pub enum ProtocolError {
    #[error("daemon I/O failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("daemon frame timed out")]
    Timeout,
    #[error("daemon frame exceeded the v2 1 MiB limit")]
    PayloadTooLarge,
    #[error("daemon returned invalid JSON: {0}")]
    InvalidJson(#[from] serde_json::Error),
    #[error("daemon did not negotiate protocol v2: {0}")]
    Negotiation(String),
    #[error("daemon could not replay from the saved cursor: {0}")]
    ReplayUnavailable(String),
}

pub async fn write_frame<W>(stream: &mut W, value: &Value) -> Result<(), ProtocolError>
where
    W: AsyncWrite + Unpin,
{
    let payload = serde_json::to_vec(value)?;
    if payload.len() > V2_MAX_PAYLOAD {
        return Err(ProtocolError::PayloadTooLarge);
    }
    let length = u32::try_from(payload.len())
        .map_err(|_| ProtocolError::PayloadTooLarge)?
        .to_be_bytes();
    timeout(FRAME_TIMEOUT, async {
        stream.write_all(&length).await?;
        stream.write_all(&payload).await?;
        stream.flush().await
    })
    .await
    .map_err(|_| ProtocolError::Timeout)??;
    Ok(())
}

pub async fn read_frame<R>(stream: &mut R) -> Result<Value, ProtocolError>
where
    R: AsyncRead + Unpin,
{
    read_frame_with_timeout(stream, FRAME_TIMEOUT).await
}

async fn read_frame_with_timeout<R>(
    stream: &mut R,
    frame_timeout: Duration,
) -> Result<Value, ProtocolError>
where
    R: AsyncRead + Unpin,
{
    let mut header = [0u8; 4];
    stream.read_exact(&mut header[..1]).await?;
    timeout(frame_timeout, async {
        stream.read_exact(&mut header[1..]).await?;
        let length = u32::from_be_bytes(header) as usize;
        if length > V2_MAX_PAYLOAD {
            return Err(ProtocolError::PayloadTooLarge);
        }
        let mut payload = vec![0u8; length];
        stream.read_exact(&mut payload).await?;
        Ok(serde_json::from_slice(&payload)?)
    })
    .await
    .map_err(|_| ProtocolError::Timeout)?
}

#[cfg(test)]
pub async fn negotiate<S>(stream: &mut S) -> Result<(), ProtocolError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    negotiate_with(stream, Uuid::new_v4(), None).await
}

pub async fn negotiate_with<S>(
    stream: &mut S,
    client_id: Uuid,
    resume_from: Option<u64>,
) -> Result<(), ProtocolError>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let hello = json!({
        "version": 2,
        "kind": "hello",
        "supportedVersions": [1, 2],
        "clientID": client_id,
        "resumeFrom": resume_from
    });
    write_frame(stream, &hello).await?;
    let response = read_frame(stream).await?;
    if response.get("kind") == Some(&Value::String("error".into())) {
        let code = response
            .pointer("/error/code")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        if matches!(code, "replayUnavailable" | "cursorOutsideWindow") {
            return Err(ProtocolError::ReplayUnavailable(code.to_owned()));
        }
    }
    if response.get("kind") != Some(&Value::String("hello".into()))
        || response.get("selectedVersion") != Some(&Value::Number(2.into()))
    {
        return Err(ProtocolError::Negotiation(response.to_string()));
    }
    Ok(())
}

pub fn request(command: Value) -> (Uuid, Value) {
    let request_id = Uuid::new_v4();
    (
        request_id,
        json!({
            "version": 2,
            "kind": "request",
            "requestID": request_id,
            "command": command
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_uses_the_authoritative_v2_envelope() {
        let (id, value) = request(json!({ "listRecentProjects": {} }));
        assert_eq!(value["version"], 2);
        assert_eq!(value["kind"], "request");
        assert_eq!(value["requestID"], id.to_string());
        assert_eq!(value["command"]["listRecentProjects"], json!({}));
    }

    #[tokio::test]
    async fn idle_wait_before_a_frame_is_not_a_frame_timeout() {
        let (mut writer, reader) = tokio::io::duplex(256);
        let mut stream = reader;
        let payload = serde_json::to_vec(&json!({
            "version": 2,
            "kind": "response",
            "requestID": Uuid::new_v4(),
            "success": true
        }))
        .unwrap();
        let mut frame = Vec::with_capacity(payload.len() + 4);
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&payload);

        let writer_task = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(40)).await;
            writer.write_all(&frame).await.unwrap();
        });

        let decoded = read_frame_with_timeout(&mut stream, Duration::from_millis(20))
            .await
            .unwrap();
        writer_task.await.unwrap();
        assert_eq!(decoded["kind"], "response");
        assert_eq!(decoded["success"], true);
    }

    #[tokio::test]
    async fn negotiation_sends_stable_client_id_and_replay_cursor() {
        let (mut client, mut server) = tokio::io::duplex(2048);
        let client_id = Uuid::parse_str("11111111-1111-4111-8111-111111111111").unwrap();

        let server_task = tokio::spawn(async move {
            let hello = read_frame(&mut server).await.unwrap();
            assert_eq!(hello["clientID"], client_id.to_string());
            assert_eq!(hello["resumeFrom"], 42);
            write_frame(
                &mut server,
                &json!({
                    "version": 2,
                    "kind": "hello",
                    "supportedVersions": [1, 2],
                    "selectedVersion": 2
                }),
            )
            .await
            .unwrap();
        });

        negotiate_with(&mut client, client_id, Some(42))
            .await
            .unwrap();
        server_task.await.unwrap();
    }

    #[tokio::test]
    async fn negotiation_classifies_replay_rejection() {
        let (mut client, mut server) = tokio::io::duplex(2048);
        let server_task = tokio::spawn(async move {
            let _ = read_frame(&mut server).await.unwrap();
            write_frame(
                &mut server,
                &json!({
                    "version": 2,
                    "kind": "error",
                    "error": {
                        "code": "cursorOutsideWindow",
                        "message": "cursor is no longer retained"
                    }
                }),
            )
            .await
            .unwrap();
        });

        assert!(matches!(
            negotiate_with(&mut client, Uuid::new_v4(), Some(1)).await,
            Err(ProtocolError::ReplayUnavailable(code))
                if code == "cursorOutsideWindow"
        ));
        server_task.await.unwrap();
    }
}
