use std::pin::Pin;

use thiserror::Error;
use tokio::io::{AsyncRead, AsyncWrite};

use crate::endpoint::DaemonEndpoint;

pub trait AsyncDaemonStream: AsyncRead + AsyncWrite + Send {}
impl<T> AsyncDaemonStream for T where T: AsyncRead + AsyncWrite + Send {}

pub type BoxedDaemonStream = Pin<Box<dyn AsyncDaemonStream>>;

#[derive(Debug, Error)]
pub enum TransportError {
    #[error("failed to connect to graphcoded at {endpoint}: {source}")]
    Connect {
        endpoint: String,
        source: std::io::Error,
    },
}

pub async fn connect(endpoint: &DaemonEndpoint) -> Result<BoxedDaemonStream, TransportError> {
    match endpoint {
        #[cfg(windows)]
        DaemonEndpoint::NamedPipe(name) => {
            use tokio::net::windows::named_pipe::ClientOptions;
            let stream =
                ClientOptions::new()
                    .open(name)
                    .map_err(|source| TransportError::Connect {
                        endpoint: name.clone(),
                        source,
                    })?;
            Ok(Box::pin(stream))
        }
        #[cfg(unix)]
        DaemonEndpoint::UnixSocket(path) => {
            let stream = tokio::net::UnixStream::connect(path)
                .await
                .map_err(|source| TransportError::Connect {
                    endpoint: path.display().to_string(),
                    source,
                })?;
            Ok(Box::pin(stream))
        }
    }
}
