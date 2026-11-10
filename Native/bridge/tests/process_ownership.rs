//! Verifies the indexed Rust-to-C ownership path with ordinary child sockets on loopback only.
#![cfg(target_os = "macos")]
use std::{io::{BufRead, BufReader}, net::{TcpListener, UdpSocket}, process::{Child, Command, Stdio}, sync::atomic::{AtomicUsize, Ordering}};
// Links the package's public SDK shim into this test executable.
extern crate hy2_bridge;

/// Includes the first-party flow cache used by the production adapter.
#[path = "../../../Patches/desktop-flow-index.rs"]
mod flow_index;
/// Includes the immutable process pattern index used by snapshot collection.
#[path = "../../../Patches/desktop-rule-index.rs"]
mod rule_index;
/// Includes the actual Rust-to-C snapshot and identity validation boundary.
#[path = "../../../Patches/desktop-process-owners.rs"]
mod process_owners;

/// Ensures a failed assertion cannot leave the disposable socket-owner process running.
struct ChildGuard(Child);
/// Stops and reaps only the child created by this test.
impl Drop for ChildGuard {
    fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); }
}

/// Proves native snapshots support cached TCP/UDP decisions and reject an exited process.
#[test]
fn native_index_reuses_snapshots_and_rejects_exited_owners() {
    for (host, udp) in [("127.0.0.1", false), ("::1", true)] {
        let tcp = TcpListener::bind((host, 0)).unwrap();
        let datagrams = UdpSocket::bind((host, 0)).unwrap();
        let destination = if udp { datagrams.local_addr().unwrap() } else { tcp.local_addr().unwrap() };
        let script = "import socket,sys; s=socket.socket(socket.AF_INET6 if ':' in sys.argv[1] else socket.AF_INET, socket.SOCK_DGRAM if sys.argv[3]=='1' else socket.SOCK_STREAM); s.connect((sys.argv[1],int(sys.argv[2]))); print(s.getsockname()[1],flush=True); sys.stdin.read(1)";
        let mut child = ChildGuard(Command::new("/usr/bin/python3").args(["-c", script, host, &destination.port().to_string(), if udp { "1" } else { "0" }])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap());
        let mut line = String::new();
        BufReader::new(child.0.stdout.take().unwrap()).read_line(&mut line).unwrap();
        let source = std::net::SocketAddr::new(destination.ip(), line.trim().parse().unwrap());
        let key = flow_index::FlowKey { source, destination, udp };
        let matcher = rule_index::RuleIndex::new(&["*".to_owned()]);
        let index = flow_index::FlowIndex::new(); let scans = AtomicUsize::new(0);
        for _ in 0..3 {
            assert!(index.resolve(key, || { scans.fetch_add(1, Ordering::SeqCst); process_owners::collect(&matcher) }, process_owners::validate));
        }
        assert_eq!(scans.load(Ordering::SeqCst), 1);
        drop(child.0.stdin.take()); child.0.wait().unwrap();
        assert!(!index.resolve(key, || process_owners::collect(&matcher), process_owners::validate));
    }
}
