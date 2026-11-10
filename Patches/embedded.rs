//! Packet-flow adapter for Apple Network Extension. Never creates a TUN or changes routes.
use crate::{Result, config::{ClientConfig, TunConfig, TunAddressConfig}, runtime::ClientHandle};
use tokio::sync::mpsc;
use std::future::Future;

/// Relays Apple packet-flow queues through a Hysteria client until shutdown.
pub async fn serve(
    mut config: ClientConfig,
    mtu: u16,
    incoming: mpsc::Receiver<Vec<u8>>,
    outgoing: mpsc::Sender<Vec<u8>>,
    ready: impl FnOnce(),
    shutdown: impl Future<Output = ()> + Send,
) -> Result<()> {
    config.validate_connection()?;
    config.lazy = false;
    tokio::pin!(shutdown);
    let client = tokio::select! {
        () = &mut shutdown => return Ok(()),
        result = ClientHandle::new(config, false) => result?,
    };
    let tun = TunConfig {
        name: String::new(), mtu, timeout: "60s".into(),
        address: TunAddressConfig::default(), route: None,
    };
    ready();
    let result = tokio::select! {
        () = &mut shutdown => Ok(()),
        result = crate::tun::serve_packets(tun, client.clone(), incoming, outgoing) => result,
    };
    let _ = tokio::time::timeout(std::time::Duration::from_secs(2), client.close()).await;
    result
}
