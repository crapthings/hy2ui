//! Provides loopback fixtures with explicit readiness and bounded, unwind-safe teardown.
use hysteria_cli::{
    cert::{self, CertOptions},
    config::ServerConfig,
    runtime::serve_server_with_ready,
};
use std::{
    io,
    net::{SocketAddr, UdpSocket},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread::{self, JoinHandle},
    time::Duration,
};
use tokio::sync::oneshot;

/// Bounds each readiness, handshake, and packet-forwarding phase independently.
pub const PHASE_TIMEOUT: Duration = Duration::from_secs(10);

/// Joins an already-completed fixture thread without allowing teardown to wait indefinitely.
struct FixtureThread {
    done: mpsc::Receiver<Result<(), String>>,
    worker: Option<JoinHandle<()>>,
}

/// Waits for fixture completion without unbounded thread joins.
impl FixtureThread {
    /// Waits for a fixture's bounded shutdown and joins only once completion is acknowledged.
    fn finish(&mut self) -> Result<(), String> {
        if self.worker.is_none() {
            return Ok(());
        }
        let result = self
            .done
            .recv_timeout(Duration::from_secs(3))
            .map_err(|error| format!("fixture shutdown did not complete: {error}"));
        match result {
            Ok(outcome) => {
                if let Some(worker) = self.worker.take() {
                    worker
                        .join()
                        .map_err(|_| "fixture thread panicked".to_string())?;
                }
                outcome
            }
            Err(error) => {
                // Dropping a JoinHandle detaches rather than blocking test unwinding forever.
                self.worker.take();
                Err(error)
            }
        }
    }
}

/// Owns a real Hysteria server bound directly to an OS-assigned loopback port.
pub struct ServerFixture {
    pub address: SocketAddr,
    pub certificate_pin: String,
    stop: Option<oneshot::Sender<()>>,
    thread: FixtureThread,
    _directory: tempfile::TempDir,
}

/// Starts and stops a readiness-aware loopback Hysteria server.
impl ServerFixture {
    /// Starts a server and waits for its actual bound address rather than reserving a port.
    pub fn start() -> Result<Self, String> {
        let directory = tempfile::tempdir().map_err(|error| error.to_string())?;
        let cert_file = directory.path().join("cert.pem");
        let key_file = directory.path().join("key.pem");
        let certificate = cert::generate(&CertOptions {
            hosts: "localhost,127.0.0.1".into(),
            cert_file: cert_file.clone(),
            key_file: key_file.clone(),
            valid_for: Duration::from_secs(3600),
            overwrite: false,
        })
        .map_err(|error| error.to_string())?;
        let config: ServerConfig = serde_json::from_value(serde_json::json!({
            "listen": "127.0.0.1:0",
            "tls": {"cert": cert_file, "key": key_file},
            "auth": {"type": "password", "password": "test-password"}
        }))
        .map_err(|error| error.to_string())?;
        let (ready, readiness) = mpsc::channel();
        let (done, completion) = mpsc::channel();
        let (stop, stopped) = oneshot::channel();
        let worker = thread::spawn(move || {
            let outcome = run_server(config, stopped, ready.clone());
            if let Err(error) = &outcome {
                let _ = ready.send(Err(error.clone()));
            }
            let _ = done.send(outcome);
        });
        let mut fixture = Self {
            address: "127.0.0.1:0".parse().expect("literal loopback address"),
            certificate_pin: certificate.pin_sha256,
            stop: Some(stop),
            thread: FixtureThread {
                done: completion,
                worker: Some(worker),
            },
            _directory: directory,
        };
        fixture.address = readiness
            .recv_timeout(PHASE_TIMEOUT)
            .map_err(|error| format!("server readiness timed out: {error}"))??;
        Ok(fixture)
    }

    /// Stops the server and exposes fixture failures during the normal test path.
    pub fn finish(&mut self) -> Result<(), String> {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        self.thread.finish()
    }
}

/// Stops the server fixture when its owner returns or unwinds.
impl Drop for ServerFixture {
    /// Requests bounded server teardown even when an assertion unwinds the test.
    fn drop(&mut self) {
        let _ = self.finish();
    }
}

/// Runs a server to shutdown and publishes readiness only after its listeners are initialized.
fn run_server(
    config: ServerConfig,
    stopped: oneshot::Receiver<()>,
    ready: mpsc::Sender<Result<SocketAddr, String>>,
) -> Result<(), String> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|error| error.to_string())?;
    let result = runtime.block_on(serve_server_with_ready(
        config,
        async {
            let _ = stopped.await;
        },
        false,
        move |address| {
            let _ = ready.send(Ok(address));
        },
    ));
    runtime.shutdown_timeout(Duration::from_secs(1));
    result.map_err(|error| error.to_string())
}

/// Owns a loopback UDP echo endpoint until the test explicitly requests teardown.
pub struct EchoFixture {
    pub port: u16,
    stop: Arc<AtomicBool>,
    thread: FixtureThread,
}

/// Starts and stops the local UDP echo fixture.
impl EchoFixture {
    /// Starts a bound echo endpoint whose lifetime is independent of handshake duration.
    pub fn start() -> Result<Self, String> {
        Self::bind("127.0.0.1:0")
    }

    /// Starts an IPv6-only loopback echo endpoint without requiring external IPv6 connectivity.
    pub fn start_ipv6() -> Result<Self, String> {
        Self::bind("[::1]:0")
    }

    /// Binds one literal loopback address with the same bounded fixture lifetime for both families.
    fn bind(address: &str) -> Result<Self, String> {
        let socket = UdpSocket::bind(address).map_err(|error| error.to_string())?;
        socket
            .set_read_timeout(Some(Duration::from_millis(50)))
            .map_err(|error| error.to_string())?;
        socket
            .set_write_timeout(Some(Duration::from_secs(1)))
            .map_err(|error| error.to_string())?;
        let port = socket
            .local_addr()
            .map_err(|error| error.to_string())?
            .port();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let (done, completion) = mpsc::channel();
        let worker = thread::spawn(move || {
            let _ = done.send(run_echo(socket, stopped));
        });
        Ok(Self {
            port,
            stop,
            thread: FixtureThread {
                done: completion,
                worker: Some(worker),
            },
        })
    }

    /// Stops echo polling and exposes fixture failures during the normal test path.
    pub fn finish(&mut self) -> Result<(), String> {
        self.stop.store(true, Ordering::Release);
        self.thread.finish()
    }
}

/// Stops the echo fixture when its owner returns or unwinds.
impl Drop for EchoFixture {
    /// Stops the echo endpoint during unwinding without a long blocking socket read.
    fn drop(&mut self) {
        let _ = self.finish();
    }
}

/// Echoes datagrams while periodically checking the explicit fixture stop signal.
fn run_echo(socket: UdpSocket, stop: Arc<AtomicBool>) -> Result<(), String> {
    let mut buffer = [0; 2048];
    while !stop.load(Ordering::Acquire) {
        match socket.recv_from(&mut buffer) {
            Ok((count, source)) => {
                socket
                    .send_to(&buffer[..count], source)
                    .map_err(|error| error.to_string())?;
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(error) => return Err(error.to_string()),
        }
    }
    Ok(())
}
