//! Shares bounded, short-lived socket ownership snapshots across concurrent new flows.
use std::{collections::HashMap, net::SocketAddr, sync::{Arc, Mutex, RwLock}, time::{Duration, Instant}};

/// Identifies a transport flow without mixing TCP, UDP, IPv4 or IPv6 ownership.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct FlowKey { pub source: SocketAddr, pub destination: SocketAddr, pub udp: bool }

/// Carries one scanned socket owner and its immutable rule decision.
#[derive(Clone)]
pub struct Record<T> { pub key: FlowKey, pub owner: T, pub direct: bool, pub unconnected: bool }

/// Indexes unconnected UDP sockets by address family and local port before checking the local address.
#[derive(Clone, Copy, Eq, PartialEq, Hash)]
struct PortKey { ipv6: bool, port: u16 }

/// Holds a complete immutable generation so readers cannot observe a partial scan.
struct Snapshot<T> {
    generation: u64,
    created: Instant,
    started: Instant,
    exact: HashMap<FlowKey, Vec<Record<T>>>,
    wildcard: HashMap<PortKey, Vec<Record<T>>>,
}

/// Builds bounded snapshots and validates candidate identity before reusing a routing decision.
impl<T: Clone> Snapshot<T> {
    fn build(generation: u64, records: Vec<Record<T>>) -> Self {
        let mut value = Self { generation, created: Instant::now(), started: Instant::now(), exact: HashMap::new(), wildcard: HashMap::new() };
        for record in records {
            if record.unconnected {
                value.wildcard.entry(PortKey { ipv6: record.key.source.is_ipv6(), port: record.key.source.port() }).or_default().push(record);
            } else { value.exact.entry(record.key).or_default().push(record); }
        }
        value
    }
    fn lookup(&self, key: FlowKey, validate: &impl Fn(&T) -> bool) -> Option<bool> {
        if let Some(records) = self.exact.get(&key) {
            if records.len() > 64 { return Some(false); }
            if !records.iter().all(|record| validate(&record.owner)) { return None; }
            return Some(records.iter().all(|record| record.direct));
        }
        if !key.udp { return None; }
        let records = self.wildcard.get(&PortKey { ipv6: key.source.is_ipv6(), port: key.source.port() })?;
        let mut candidates = records.iter().filter(|record| record.key.source.ip().is_unspecified() || record.key.source.ip() == key.source.ip());
        let candidate = candidates.next()?;
        if candidates.next().is_some() { return Some(false); }
        validate(&candidate.owner).then_some(candidate.direct)
    }
}

/// Serializes refreshes while allowing validated hits to read an immutable snapshot concurrently.
pub struct FlowIndex<T> { snapshot: RwLock<Arc<Snapshot<T>>>, refresh: Mutex<()> }

/// Applies a 250 ms snapshot lifetime and batches cold misses at most once every 20 ms.
impl<T: Clone> FlowIndex<T> {
    pub fn new() -> Self {
        let mut snapshot = Snapshot::build(0, Vec::new());
        snapshot.created = Instant::now() - Duration::from_secs(1);
        Self { snapshot: RwLock::new(Arc::new(snapshot)), refresh: Mutex::new(()) }
    }
    pub fn resolve(&self, key: FlowKey, scan: impl FnOnce() -> Option<Vec<Record<T>>>, validate: impl Fn(&T) -> bool) -> bool {
        let requested = Instant::now();
        let current = Arc::clone(&self.snapshot.read().unwrap_or_else(|e| e.into_inner()));
        if current.created.elapsed() < Duration::from_millis(250) {
            if let Some(direct) = current.lookup(key, &validate) { return direct; }
        }
        let _refresh = self.refresh.lock().unwrap_or_else(|e| e.into_inner());
        let latest = Arc::clone(&self.snapshot.read().unwrap_or_else(|e| e.into_inner()));
        if latest.generation != current.generation && latest.created.elapsed() < Duration::from_millis(250) {
            if let Some(direct) = latest.lookup(key, &validate) { return direct; }
            // A scan already started after this flow appeared is a sufficient negative result.
            if latest.started >= requested { return false; }
        }
        if let Some(wait) = Duration::from_millis(20).checked_sub(latest.created.elapsed()) { std::thread::sleep(wait); }
        let started = Instant::now();
        let records = scan().unwrap_or_default();
        // Reject oversized scans as a whole rather than publishing a truncated ownership view.
        let records = if records.len() <= 32_768 { records } else { Vec::new() };
        let mut next = Snapshot::build(latest.generation.wrapping_add(1), records);
        next.started = started;
        let next = Arc::new(next);
        *self.snapshot.write().unwrap_or_else(|e| e.into_inner()) = Arc::clone(&next);
        next.lookup(key, &validate).unwrap_or(false)
    }
}

/// Exercises cache reuse, invalidation and refresh sharing with deterministic in-memory socket owners.
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{atomic::{AtomicUsize, Ordering}, Barrier};

    /// Produces one IPv4 TCP tuple without opening a socket.
    fn key() -> FlowKey {
        FlowKey { source: "127.0.0.1:32001".parse().unwrap(), destination: "127.0.0.1:443".parse().unwrap(), udp: false }
    }
    /// Produces one visible owner whose token stands in for native PID and socket identity.
    fn record(key: FlowKey, owner: u64, direct: bool) -> Record<u64> { Record { key, owner, direct, unconnected: false } }

    /// Reuses exact-key decisions without invoking a global scan again.
    #[test]
    fn repeated_hits_do_not_scan() {
        let index = FlowIndex::new(); let scans = AtomicUsize::new(0);
        for _ in 0..100 {
            assert!(index.resolve(key(), || { scans.fetch_add(1, Ordering::SeqCst); Some(vec![record(key(), 1, true)]) }, |_| true));
        }
        assert_eq!(scans.load(Ordering::SeqCst), 1);
    }
    /// Rebuilds an indexed tuple when its process or socket identity stops validating.
    #[test]
    fn reused_identity_refreshes_before_routing() {
        let index = FlowIndex::new();
        assert!(index.resolve(key(), || Some(vec![record(key(), 1, true)]), |_| true));
        assert!(!index.resolve(key(), || Some(vec![record(key(), 2, false)]), |owner| *owner == 2));
        assert!(!index.resolve(key(), || panic!("validated replacement should hit"), |owner| *owner == 2));
    }
    /// Keeps TCP, UDP and both address families in distinct lookup keys.
    #[test]
    fn protocol_and_family_are_separate() {
        let tcp4 = key(); let udp4 = FlowKey { udp: true, ..tcp4 };
        let tcp6 = FlowKey { source: "[::1]:32001".parse().unwrap(), destination: "[::1]:443".parse().unwrap(), udp: false };
        let udp6 = FlowKey { udp: true, ..tcp6 };
        let index = FlowIndex::new();
        assert!(index.resolve(tcp4, || Some(vec![record(tcp4, 1, true), record(udp4, 2, false), record(tcp6, 3, false), record(udp6, 4, true)]), |_| true));
        for (key, expected) in [(udp4, false), (tcp6, false), (udp6, true)] {
            assert_eq!(index.resolve(key, || panic!("snapshot should cover all protocols"), |_| true), expected);
        }
    }
    /// Prioritizes exact connected UDP owners and rejects ambiguous unconnected owners.
    #[test]
    fn udp_ambiguity_and_precedence() {
        let query = FlowKey { udp: true, ..key() };
        let wildcard = Record { key: FlowKey { source: "0.0.0.0:32001".parse().unwrap(), destination: "0.0.0.0:0".parse().unwrap(), udp: true },
            owner: 1, direct: true, unconnected: true };
        let index = FlowIndex::new();
        assert!(!index.resolve(query, || Some(vec![wildcard.clone(), record(query, 2, false)]), |_| true));
        let shared = FlowIndex::new();
        assert!(!shared.resolve(query, || Some(vec![wildcard.clone(), wildcard]), |_| true));
    }
    /// Requires all visible exact owners to allow direct routing.
    #[test]
    fn conflicting_exact_owners_stay_proxied() {
        let index = FlowIndex::new();
        assert!(!index.resolve(key(), || Some(vec![record(key(), 1, true), record(key(), 2, false)]), |_| true));
    }
    /// Publishes one generation for concurrent flow lookups rather than enumerating processes per caller.
    #[test]
    fn concurrent_cold_queries_share_one_scan() {
        let index = Arc::new(FlowIndex::new()); let scans = Arc::new(AtomicUsize::new(0)); let barrier = Arc::new(Barrier::new(16));
        let mut threads = Vec::new();
        for port in 32000..32016 {
            let (index, scans, barrier) = (Arc::clone(&index), Arc::clone(&scans), Arc::clone(&barrier));
            threads.push(std::thread::spawn(move || {
                barrier.wait(); let query = FlowKey { source: SocketAddr::new(key().source.ip(), port), ..key() };
                index.resolve(query, || {
                    scans.fetch_add(1, Ordering::SeqCst);
                    Some((32000..32016).map(|port| record(FlowKey { source: SocketAddr::new(key().source.ip(), port), ..key() }, 1, true)).collect())
                }, |_| true)
            }));
        }
        for thread in threads { assert!(thread.join().unwrap()); }
        assert_eq!(scans.load(Ordering::SeqCst), 1);
    }
    /// Discards expired generations and failed scans without retaining an earlier direct decision.
    #[test]
    fn expiration_and_failed_scan_fail_closed() {
        let index = FlowIndex::new(); let mut snapshot = Snapshot::build(42, vec![record(key(), 1, true)]);
        snapshot.created = Instant::now() - Duration::from_secs(1);
        *index.snapshot.write().unwrap() = Arc::new(snapshot);
        assert!(!index.resolve(key(), || None, |_| true));
        assert!(index.snapshot.read().unwrap().exact.is_empty());
    }
    /// Rejects truncated oversized input instead of misclassifying a shared tuple from partial data.
    #[test]
    fn oversized_snapshot_is_not_published() {
        let index = FlowIndex::new();
        assert!(!index.resolve(key(), || Some(vec![record(key(), 1, true); 32_769]), |_| true));
        assert!(index.snapshot.read().unwrap().exact.is_empty());
    }
}
