//! Desktop worker: reads credentials from stdin and exits when its owning UI disappears.
use hysteria_cli::{config::ClientConfig, runtime::serve_client};
use std::{
    io::{self, Read},
    time::Duration,
};

/// Limits the in-memory configuration accepted from the owning UI.
const MAX_CONFIGURATION_BYTES: u64 = 1_048_576;

/// Runs the proxy worker and reports failures without echoing configuration contents.
#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

/// Parses a bounded JSON configuration without creating a plaintext credential file.
fn read_configuration(reader: impl Read) -> Result<ClientConfig, Box<dyn std::error::Error>> {
    let mut bytes = Vec::new();
    reader
        .take(MAX_CONFIGURATION_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_CONFIGURATION_BYTES {
        return Err("invalid client configuration size".into());
    }
    let config: ClientConfig =
        serde_json::from_slice(&bytes).map_err(|_| "invalid client configuration")?;
    config.validate()?;
    Ok(config)
}

/// Serves configured proxies until interrupted or the parent UI process disappears.
async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args != ["--config-stdin"] {
        return Err("--config-stdin is required".into());
    }
    // SAFETY: getppid has no preconditions and does not retain any pointers.
    let parent = unsafe { libc::getppid() };
    if parent <= 1 {
        return Err("desktop worker requires a live parent process".into());
    }
    let config = read_configuration(io::stdin().lock())?;
    let shutdown = async move {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = async {
                loop {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    if unsafe { libc::getppid() } != parent { break; }
                }
            } => {},
        }
    };
    let (stop, stopped) = tokio::sync::oneshot::channel();
    let serving = serve_client(
        config,
        async {
            let _ = stopped.await;
        },
        false,
    );
    tokio::pin!(serving);
    tokio::select! {
        result = &mut serving => result?,
        () = shutdown => {
            let _ = stop.send(());
            // Bound shutdown even when the core is still establishing its first QUIC connection.
            let _ = tokio::time::timeout(Duration::from_secs(2), &mut serving).await;
        }
    }
    Ok(())
}

/// Verifies the worker configuration boundary without starting any network listeners.
#[cfg(test)]
mod tests {
    use super::*;

    /// Ensures malformed input errors do not contain credential bytes.
    #[test]
    fn rejects_invalid_json_without_echoing_credentials() {
        let error = read_configuration(&b"secret-password-invalid-json"[..]).unwrap_err();
        assert_eq!(error.to_string(), "invalid client configuration");
    }

    /// Rejects configurations larger than the explicit memory bound.
    #[test]
    fn rejects_oversized_configuration() {
        let bytes = vec![b' '; MAX_CONFIGURATION_BYTES as usize + 1];
        assert_eq!(
            read_configuration(bytes.as_slice())
                .unwrap_err()
                .to_string(),
            "invalid client configuration size"
        );
    }

    /// Preserves JSON-escaped credentials while reading a valid local proxy configuration.
    #[test]
    fn reads_json_credentials_without_reinterpretation() {
        let password = "secret\nhttp:\n  listen: 0.0.0.0:80\"\\";
        let bytes = serde_json::to_vec(&serde_json::json!({
            "server": "example.com:443", "auth": password,
            "http": {"listen": "127.0.0.1:18080"},
            "socks5": {"listen": "127.0.0.1:11080"}
        }))
        .unwrap();
        let config = read_configuration(bytes.as_slice()).unwrap();
        assert_eq!(config.auth, password);
    }
}
