//! Plans interface-scoped physical defaults needed by DIRECT sockets alongside TUN split defaults.
#[cfg(target_os = "macos")]
use route_manager::Route;

/// Copies only selected physical defaults and leaves existing scoped routes owned by other software untouched.
#[cfg(target_os = "macos")]
pub fn plan(original: &[Route], ipv4: u32, ipv6: u32) -> Vec<Route> {
    let mut planned = Vec::new();
    for (is_v6, index) in [(false, ipv4), (true, ipv6)] {
        if index == 0 { continue; }
        let candidates: Vec<_> = original.iter().filter(|route| route.prefix() == 0
            && route.destination().is_ipv6() == is_v6 && route.if_index() == Some(index)).collect();
        if candidates.iter().any(|route| route.if_scope()) { continue; }
        if let Some(base) = candidates.first() { planned.push((*base).clone().with_if_scope(true)); }
    }
    planned
}

/// Preserves replacement routes while cleaning up only exact scoped routes installed by this session.
#[cfg(target_os = "macos")]
pub fn still_owned(installed: &Route, current: &[Route]) -> bool {
    current.iter().any(|route| route == installed)
}

/// Stores only the fixed default-route identity required for conservative crash recovery.
#[cfg(target_os = "macos")]
#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct SavedRoute { ipv6: bool, index: u32, gateway: Option<std::net::IpAddr>, name: Option<String> }

/// Converts a bounded journal entry into the same scoped route created by the plan.
#[cfg(target_os = "macos")]
impl SavedRoute {
    fn from_route(route: &Route) -> Self { Self { ipv6: route.destination().is_ipv6(), index: route.if_index().unwrap_or(0), gateway: route.gateway(), name: route.if_name().cloned() } }
    fn route(&self) -> std::io::Result<Route> {
        if self.index == 0 || self.index > u16::MAX as u32 || self.gateway.is_some_and(|ip| ip.is_ipv6() != self.ipv6)
            || self.name.as_ref().is_some_and(|name| name.is_empty() || name.len() > 15 || !name.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))) {
            return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
        }
        let address = if self.ipv6 { "::" } else { "0.0.0.0" }.parse().unwrap();
        let mut route = Route::new(address, 0).with_if_index(self.index).with_if_scope(true);
        if let Some(gateway) = self.gateway { route = route.with_gateway(gateway); }
        if let Some(name) = &self.name { route = route.with_if_name(name.clone()); }
        Ok(route)
    }
}

/// Versions the bounded crash-recovery payload independently from user routing preferences.
#[cfg(target_os = "macos")]
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct SavedRoutes { version: u32, routes: Vec<SavedRoute> }

/// Identifies the protected recovery file shared by the privileged worker and its supervisor.
#[cfg(target_os = "macos")]
const JOURNAL: &str = "/Library/PrivilegedHelperTools/dev.hy2ui/direct-routes.json";

/// Rejects untrusted journal parents and files before privileged recovery accesses their contents.
#[cfg(target_os = "macos")]
fn check_journal() -> std::io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let parent = std::path::Path::new(JOURNAL).parent().unwrap();
    let metadata = std::fs::symlink_metadata(parent)?;
    if !metadata.is_dir() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 { return Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied)); }
    match std::fs::symlink_metadata(JOURNAL) {
        Ok(metadata) if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o077 != 0 => Err(std::io::Error::from(std::io::ErrorKind::PermissionDenied)),
        Ok(_) => Ok(()), Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()), Err(error) => Err(error),
    }
}

/// Atomically records bounded owned routes before installation without following caller-controlled paths.
#[cfg(target_os = "macos")]
fn write_journal(routes: &[Route]) -> std::io::Result<()> {
    use std::{io::Write, os::unix::fs::OpenOptionsExt};
    check_journal()?;
    if routes.is_empty() { return match std::fs::remove_file(JOURNAL) { Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error), _ => Ok(()) }; }
    if routes.len() > 2 { return Err(std::io::Error::from(std::io::ErrorKind::InvalidData)); }
    let data = serde_json::to_vec(&SavedRoutes { version: 1, routes: routes.iter().map(SavedRoute::from_route).collect() })?;
    let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
    let temporary = format!("{JOURNAL}.{}.{nonce}.tmp", std::process::id());
    let result = (|| {
        let mut file = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&temporary)?;
        file.write_all(&data)?; file.sync_all()?; std::fs::rename(&temporary, JOURNAL)
    })();
    let _ = std::fs::remove_file(temporary);
    result
}

/// Removes only journaled routes whose complete identity still matches the current routing table.
#[cfg(target_os = "macos")]
pub fn recover() -> std::io::Result<()> {
    use std::io::Read;
    if !std::path::Path::new(JOURNAL).exists() { return Ok(()); }
    check_journal()?;
    let mut data = Vec::new(); std::fs::File::open(JOURNAL)?.take(16_385).read_to_end(&mut data)?;
    if data.len() > 16_384 { return Err(std::io::Error::from(std::io::ErrorKind::InvalidData)); }
    let saved: SavedRoutes = serde_json::from_slice(&data)?;
    if saved.version != 1 || saved.routes.len() > 2 { return Err(std::io::Error::from(std::io::ErrorKind::InvalidData)); }
    let routes = saved.routes.iter().map(SavedRoute::route).collect::<std::io::Result<Vec<_>>>()?;
    let mut manager = route_manager::RouteManager::new()?;
    for route in routes.iter().rev() {
        if still_owned(route, &manager.list()?) { manager.delete(route)?; }
    }
    std::fs::remove_file(JOURNAL)
}

/// Owns scoped physical defaults and their crash journal for one privileged TUN session.
#[cfg(target_os = "macos")]
pub struct DirectRoutes { routes: Vec<Route>, manager: route_manager::RouteManager }

/// Installs scoped routes transactionally while tracking successful additions for normal cleanup.
#[cfg(target_os = "macos")]
impl DirectRoutes {
    pub fn install(original: &[Route], ipv4: u32, ipv6: u32) -> std::io::Result<Self> {
        let mut value = Self { routes: Vec::new(), manager: route_manager::RouteManager::new()? };
        for route in plan(original, ipv4, ipv6) {
            let mut pending = value.routes.clone(); pending.push(route.clone()); write_journal(&pending)?;
            if let Err(error) = value.manager.add(&route) { write_journal(&value.routes)?; return Err(error); }
            value.routes.push(route);
        }
        Ok(value)
    }
}

/// Restores owned defaults on graceful shutdown and leaves the journal intact if recovery fails.
#[cfg(target_os = "macos")]
impl Drop for DirectRoutes {
    fn drop(&mut self) {
        if !self.routes.is_empty() {
            if let Err(error) = recover() { eprintln!("scoped direct route recovery failed: {error}"); }
        }
    }
}

/// Verifies journal model roundtrips and validation with synthetic routes only.
#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    /// Roundtrips only the exact scoped default identity required for cleanup.
    #[test]
    fn saved_route_roundtrips_without_privileged_io() {
        let route = Route::new("0.0.0.0".parse().unwrap(), 0).with_if_index(19).with_if_name("en1".into())
            .with_gateway("192.168.50.1".parse().unwrap()).with_if_scope(true);
        let bytes = serde_json::to_vec(&SavedRoute::from_route(&route)).unwrap();
        let saved: SavedRoute = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(saved.route().unwrap(), route);
    }
    /// Rejects invalid indices, mixed families, oversized names and unknown journal fields.
    #[test]
    fn invalid_saved_routes_are_rejected_without_io() {
        let base = SavedRoute { ipv6: false, index: 19, gateway: Some("192.168.50.1".parse().unwrap()), name: Some("en1".into()) };
        let mut invalid = base.clone(); invalid.index = 0; assert!(invalid.route().is_err());
        let mut invalid = base.clone(); invalid.ipv6 = true; assert!(invalid.route().is_err());
        let mut invalid = base.clone(); invalid.name = Some("/tmp/inject".into()); assert!(invalid.route().is_err());
        assert!(serde_json::from_str::<SavedRoute>(r#"{"ipv6":false,"index":19,"gateway":null,"name":null,"command":"unsafe"}"#).is_err());
    }
}
