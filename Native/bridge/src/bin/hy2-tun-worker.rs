//! Runs the fixed local TUN data plane only after the helper has obtained root authorization.
use hysteria_cli::runtime::serve_client;
use std::{io, net::SocketAddr, time::Duration};

/// Validates the privileged stdin boundary and constructs a fixed route plan.
#[path = "local_tun/configuration.rs"]
mod configuration;
/// Builds core configuration without accepting arbitrary privileged fields.
#[path = "local_tun/plan.rs"]
mod plan;

/// Starts an explicitly bounded runtime and reports errors without printing the input configuration.
fn main() {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => {
            eprintln!("error: failed to create local TUN runtime");
            std::process::exit(1);
        }
    };
    let result = runtime.block_on(run());
    runtime.shutdown_timeout(Duration::from_secs(1));
    if let Err(error) = result {
        eprintln!("error: {error}");
        std::process::exit(1);
    }
}

/// Refuses unprivileged execution and serves the TUN until a signal or supervisor exit requests cleanup.
async fn run() -> Result<(), String> {
    if std::env::args().skip(1).collect::<Vec<_>>() != ["--config-stdin"] {
        return Err("--config-stdin is required".into());
    }
    // SAFETY: geteuid and getppid have no preconditions or pointer arguments.
    let (user, parent) = unsafe { (libc::geteuid(), libc::getppid()) };
    validate_supervisor(user, parent)?;
    let input = configuration::read_configuration(io::stdin().lock())?;
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .map_err(|_| "failed to observe local TUN termination".to_string())?;
    let shutdown = async {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {},
            _ = terminate.recv() => {},
            _ = supervisor_exit(parent) => {},
        }
    };
    let (stop, stopped) = tokio::sync::oneshot::channel();
    let serving = async move {
        let endpoint = resolve_endpoint(&input).await?;
        let name = plan::available_interface_name()?;
        let plan = plan::TunPlan::build(&input, endpoint, &name)?;
        serve_client(
            plan.config,
            async {
                let _ = stopped.await;
            },
            false,
        )
        .await
        .map_err(|error| error.to_string())
    };
    tokio::pin!(serving);
    tokio::select! {
        result = &mut serving => result,
        () = shutdown => {
            let _ = stop.send(());
            let _ = tokio::time::timeout(Duration::from_secs(2), &mut serving).await;
            Ok(())
        }
    }
}

/// Resolves the endpoint before routes or DNS settings change and prefers ordinary IPv4 when available.
async fn resolve_endpoint(
    input: &configuration::LocalTunConfiguration,
) -> Result<SocketAddr, String> {
    let addresses = tokio::time::timeout(
        Duration::from_secs(15),
        tokio::net::lookup_host((input.host.as_str(), input.port)),
    )
    .await
    .map_err(|_| "local TUN server DNS resolution timed out".to_string())?
    .map_err(|_| "local TUN server DNS resolution failed".to_string())?;
    let mut addresses: Vec<_> = addresses.collect();
    addresses.sort_by_key(|address| address.is_ipv6());
    addresses
        .into_iter()
        .next()
        .ok_or_else(|| "local TUN server has no usable IP address".into())
}

/// Polls the trusted supervisor identity without persisting credentials or altering system settings.
async fn supervisor_exit(parent: libc::pid_t) {
    loop {
        tokio::time::sleep(Duration::from_millis(250)).await;
        // SAFETY: getppid has no preconditions or pointer arguments.
        if unsafe { libc::getppid() } != parent {
            return;
        }
    }
}

/// Rejects unprivileged or orphaned workers before configuration parsing or interface creation.
fn validate_supervisor(user: libc::uid_t, parent: libc::pid_t) -> Result<(), String> {
    if user != 0 {
        return Err("local TUN worker requires administrator authorization".into());
    }
    if parent <= 1 {
        return Err("local TUN worker requires a live supervisor".into());
    }
    Ok(())
}

/// Checks the authorization boundary without launching a privileged worker.
#[cfg(test)]
mod tests {
    use super::*;

    /// Requires both an effective root identity and a live non-launchd supervisor.
    #[test]
    fn refuses_unprivileged_or_orphaned_execution() {
        assert!(validate_supervisor(501, 100).is_err());
        assert!(validate_supervisor(0, 1).is_err());
        assert!(validate_supervisor(0, 0).is_err());
        assert!(validate_supervisor(0, 100).is_ok());
    }
}
