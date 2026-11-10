//! Owns native packet-worker allocation and teardown independently of the C boundary.
use crate::EngineState;
use hysteria_cli::config::ClientConfig;
use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU8, Ordering},
    },
    thread,
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};

/// Owns the packet queues and worker lifetime for one native tunnel session.
pub struct Engine {
    pub(super) input: mpsc::Sender<Vec<u8>>,
    pub(super) output: Mutex<mpsc::Receiver<Vec<u8>>>,
    pub(super) state: Arc<AtomicU8>,
    pub(super) error: Arc<Mutex<String>>,
    stop: Option<oneshot::Sender<()>>,
    worker: Option<thread::JoinHandle<()>>,
}

/// Creates a bounded packet engine and launches its dedicated async runtime.
pub(super) fn start(config: ClientConfig, mtu: u16) -> Result<Engine, String> {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let (input, incoming) = mpsc::channel(256);
    let (outgoing, output) = mpsc::channel(256);
    let (stop, shutdown) = oneshot::channel();
    let state = Arc::new(AtomicU8::new(EngineState::Connecting as u8));
    let error = Arc::new(Mutex::new(String::new()));
    let worker_state = state.clone();
    let worker_error = error.clone();
    let session = WorkerSession {
        config,
        mtu,
        incoming,
        outgoing,
        shutdown,
        worker_state,
        worker_error,
    };
    let worker = thread::Builder::new()
        .name("hy2-packet-engine".into())
        .spawn(move || session.run(runtime))
        .map_err(|e| e.to_string())?;
    Ok(Engine {
        input,
        output: Mutex::new(output),
        state,
        error,
        stop: Some(stop),
        worker: Some(worker),
    })
}

/// Implements cooperative teardown for the owned native worker.
impl Engine {
    /// Joins the native worker after requesting its cooperative shutdown.
    pub(super) fn stop(mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

/// Carries the owned resources needed to run one packet worker to completion.
struct WorkerSession {
    config: ClientConfig,
    mtu: u16,
    incoming: mpsc::Receiver<Vec<u8>>,
    outgoing: mpsc::Sender<Vec<u8>>,
    shutdown: oneshot::Receiver<()>,
    worker_state: Arc<AtomicU8>,
    worker_error: Arc<Mutex<String>>,
}

/// Runs the worker session on its dedicated asynchronous runtime.
impl WorkerSession {
    /// Runs the tunnel and publishes its terminal state before shutting down the runtime.
    fn run(self, runtime: tokio::runtime::Runtime) {
        let Self {
            config,
            mtu,
            incoming,
            outgoing,
            shutdown,
            worker_state,
            worker_error,
        } = self;

        let result = catch_unwind(AssertUnwindSafe(|| {
            runtime.block_on(async {
                let ready_state = worker_state.clone();
                hysteria_cli::embedded::serve(
                    config,
                    mtu,
                    incoming,
                    outgoing,
                    move || {
                        ready_state.store(EngineState::Connected as u8, Ordering::Release);
                    },
                    async {
                        let _ = shutdown.await;
                    },
                )
                .await
            })
        }));
        match result {
            Ok(Ok(())) => {
                worker_state.store(EngineState::Stopped as u8, Ordering::Release);
            }
            other => {
                let message = match other {
                    Ok(Err(e)) => e.to_string(),
                    _ => "packet engine panicked".into(),
                };
                if let Ok(mut error) = worker_error.lock() {
                    *error = message;
                }
                worker_state.store(EngineState::Failed as u8, Ordering::Release);
            }
        }
        runtime.shutdown_timeout(Duration::from_secs(2));
    }
}
