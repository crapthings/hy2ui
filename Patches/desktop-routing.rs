//! Routes explicitly matched macOS application flows through sockets bound to the pre-TUN interface.
// Only this adapter may cross the audited SDK shim boundary.
#![allow(unsafe_code)]
use std::{io, net::{SocketAddr}, sync::{Arc, OnceLock}, time::Duration};
use tokio::net::{TcpSocket, TcpStream, UdpSocket};

/// Indexes compiled process patterns independently from socket metadata collection.
#[path = "desktop_rule_index.rs"]
mod rule_index;
/// Batches socket ownership refreshes independently from native SDK calls.
#[path = "desktop_flow_index.rs"]
mod flow_index;
/// Uses the macOS SDK adapter only when local process rules are explicitly enabled.
#[path = "desktop_process_owners.rs"]
mod process_owners;

/// Marks a missing local address-family exit independently from a remote target failure.
#[derive(Debug)]
pub struct DirectEgressUnavailable { pub ipv6: bool }
/// Gives the error a fixed message without exposing network configuration.
impl std::fmt::Display for DirectEgressUnavailable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(if self.ipv6 { "local IPv6 direct egress unavailable" } else { "local IPv4 direct egress unavailable" })
    }
}
/// Allows diagnostics to downcast a missing-exit error without parsing arbitrary strings.
impl std::error::Error for DirectEgressUnavailable {}

/// Exposes captured physical indices when application or IP routing rules need bound egress.
pub fn direct_interfaces() -> Option<(u32, u32)> { RULES.get().map(|rules| (rules.ipv4, rules.ipv6)) }

/// Holds immutable per-worker process patterns and physical interface indices.
struct Rules { matcher: rule_index::RuleIndex, owners: flow_index::FlowIndex<process_owners::Owner>, ipv4: u32, ipv6: u32, addresses: crate::desktop_address_policy::AddressIndex, has_processes: bool }
/// Enables application routing only for a worker explicitly configured by the local helper.
static RULES: OnceLock<Arc<Rules>> = OnceLock::new();
/// Limits expensive kernel metadata scans without blocking Tokio's network threads.
static LOOKUPS: std::sync::LazyLock<Arc<tokio::sync::Semaphore>> = std::sync::LazyLock::new(|| Arc::new(tokio::sync::Semaphore::new(4)));

/// Compiles application and IP rules and captures physical interfaces before TUN routes are installed.
pub fn configure(patterns: Vec<String>, addresses: Vec<String>) -> Result<(), String> {
    if patterns.is_empty() && addresses.is_empty() { return Ok(()); }
    let addresses = crate::desktop_address_policy::AddressIndex::new(&addresses)?;
    if patterns.len() > 64 || patterns.iter().any(|p| p.is_empty() || p.len() > 1024 || p.chars().any(char::is_control)
        || p.contains([',', '\\']) || p.trim() != p || (p.contains('/') && !p.starts_with('/'))) {
        return Err("invalid application routing patterns".into());
    }
    #[cfg(target_os = "macos")]
    {
        // SAFETY: the shim reads system interface metadata and takes no pointers.
        let (ipv4, ipv6, available) = unsafe { (hy2_direct_interface(0), hy2_direct_interface(1), hy2_process_lookup_available()) };
        if !patterns.is_empty() && available != 1 { return Err("process routing metadata is unavailable on this system".into()); }
        if ipv4 == 0 && ipv6 == 0 { return Err("no physical interface is available for direct routing".into()); }
        RULES.set(Arc::new(Rules { has_processes: !patterns.is_empty(), addresses, matcher: rule_index::RuleIndex::new(&patterns), owners: flow_index::FlowIndex::new(), ipv4, ipv6 })).map_err(|_| "application routing was already configured".to_string())
    }
    #[cfg(not(target_os = "macos"))]
    { Err("application routing is supported only on macOS".into()) }
}

/// Matches filename globs, absolute path globs and trailing-slash bundle prefixes case-sensitively.
pub fn matches(pattern: &str, path: &str) -> bool {
    rule_index::RuleIndex::new(&[pattern.to_owned()]).matches(path)
}

/// Opens an explicitly matched TCP flow directly and returns no decision when ownership is unknown.
pub(crate) async fn direct_tcp(source: SocketAddr, destination: SocketAddr) -> Option<io::Result<TcpStream>> {
    let rules = selected(source, destination, false).await?;
    let index = if destination.is_ipv6() { rules.ipv6 } else { rules.ipv4 };
    Some(async {
        let socket = if destination.is_ipv6() { TcpSocket::new_v6()? } else { TcpSocket::new_v4()? };
        bind(&socket, destination.is_ipv6(), index)?;
        tokio::time::timeout(Duration::from_secs(10), socket.connect(scoped(destination, index)))
            .await.map_err(|_| io::Error::from(io::ErrorKind::TimedOut))?
    }.await)
}

/// Creates a connected direct UDP socket for one matched flow without changing system routes.
pub(crate) async fn direct_udp(source: SocketAddr, destination: SocketAddr) -> Option<io::Result<UdpSocket>> {
    let rules = selected(source, destination, true).await?;
    let index = if destination.is_ipv6() { rules.ipv6 } else { rules.ipv4 };
    Some(async {
        let socket = UdpSocket::bind(if destination.is_ipv6() { "[::]:0" } else { "0.0.0.0:0" }).await?;
        bind(&socket, destination.is_ipv6(), index)?;
        socket.connect(scoped(destination, index)).await?;
        Ok(socket)
    }.await)
}

/// Looks up flow ownership on a bounded blocking pool and leaves ambiguous or unavailable flows proxied.
async fn selected(source: SocketAddr, destination: SocketAddr, udp: bool) -> Option<Arc<Rules>> {
    let rules = Arc::clone(RULES.get()?);
    if let Some(direct) = rules.addresses.decision(destination.ip()) { return direct.then_some(rules); }
    if !rules.has_processes { return None; }
    let permit = tokio::time::timeout(Duration::from_millis(150), Arc::clone(&LOOKUPS).acquire_owned()).await.ok()?.ok()?;
    let test = Arc::clone(&rules);
    let matched = tokio::task::spawn_blocking(move || { let _permit = permit; native_match(&test, source, destination, udp) }).await.ok()?;
    matched.then_some(rules)
}

/// Applies the required scope to link-local IPv6 destinations on the captured interface.
fn scoped(mut address: SocketAddr, index: u32) -> SocketAddr {
    if let SocketAddr::V6(ref mut v6) = address {
        if v6.ip().is_unicast_link_local() { v6.set_scope_id(index); }
    }
    address
}

/// Binds only the new outbound socket and refuses direct routing if its interface is unavailable.
#[cfg(unix)]
fn bind(socket: &impl std::os::fd::AsRawFd, ipv6: bool, index: u32) -> io::Result<()> {
    if index == 0 { return Err(io::Error::new(io::ErrorKind::NetworkUnreachable, DirectEgressUnavailable { ipv6 })); }
    #[cfg(target_os = "macos")]
    {
        // SAFETY: descriptor and interface index refer to this owned socket and captured system metadata.
        if unsafe { hy2_bind_direct_socket(socket.as_raw_fd(), i32::from(ipv6), index) } == 0 { Ok(()) }
        else { Err(io::Error::last_os_error()) }
    }
    #[cfg(not(target_os = "macos"))]
    { let _ = (socket, ipv6, index); Err(io::Error::from(io::ErrorKind::Unsupported)) }
}

/// Keeps non-Unix builds type-correct while leaving application bypass unavailable.
#[cfg(not(unix))]
fn bind<T>(_: &T, _: bool, _: u32) -> io::Result<()> { Err(io::Error::from(io::ErrorKind::Unsupported)) }

/// Uses an immutable flow index and validates cached owners without another global process scan.
fn native_match(rules: &Rules, source: SocketAddr, destination: SocketAddr, udp: bool) -> bool {
    rules.owners.resolve(flow_index::FlowKey { source, destination, udp },
        || process_owners::collect(&rules.matcher), process_owners::validate)
}

// Declares the narrow, read-only process lookup and owned-socket binding adapter.
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn hy2_process_lookup_available() -> i32;
    fn hy2_direct_interface(ipv6: i32) -> u32;
    fn hy2_bind_direct_socket(descriptor: i32, ipv6: i32, index: u32) -> i32;

}
