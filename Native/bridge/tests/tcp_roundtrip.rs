//! Verifies TCP byte integrity through the actual Hy2 packet engine and loopback-only server.
use hy2_bridge::{
    Engine, EngineState, ReadStatus, WriteResult, hy2_read, hy2_start, hy2_state, hy2_stop,
    hy2_write,
};
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpListener},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

/// Supplies the certificate-pinned loopback Hy2 server with bounded teardown.
#[allow(dead_code)]
mod support;
/// Supplies shared checksum-correct raw TCP packets without using host routes.
#[allow(dead_code)]
#[path = "support/tcp_packets.rs"]
mod tcp_packets;

/// Stops the isolated packet engine on normal completion and failed assertions.
struct PacketEngine(*mut Engine);
/// Provides bounded packet-engine calls without creating a TUN interface.
impl PacketEngine {
    fn start(server: &support::ServerFixture) -> Self {
        let config = serde_json::to_vec(
            &serde_json::json!({"server":server.address.to_string(),"auth":"test-password",
            "tls":{"sni":"localhost","insecure":true,"pinSHA256":server.certificate_pin}}),
        )
        .unwrap();
        let mut error = [0; 2048];
        let engine = Self(unsafe {
            hy2_start(
                config.as_ptr(),
                config.len(),
                1400,
                error.as_mut_ptr(),
                error.len(),
            )
        });
        assert!(!engine.0.is_null(), "{}", String::from_utf8_lossy(&error));
        let deadline = Instant::now() + support::PHASE_TIMEOUT;
        while unsafe { hy2_state(engine.0) } == EngineState::Connecting && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(unsafe { hy2_state(engine.0) }, EngineState::Connected);
        engine
    }
    fn send(&self, packet: Vec<u8>) {
        let deadline = Instant::now() + support::PHASE_TIMEOUT;
        loop {
            match unsafe { hy2_write(self.0, packet.as_ptr(), packet.len()) } {
                WriteResult::Accepted => return,
                WriteResult::Full if Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(1))
                }
                other => panic!("packet input failed: {other:?}"),
            }
        }
    }
    fn receive(&self) -> Vec<u8> {
        let deadline = Instant::now() + support::PHASE_TIMEOUT;
        let mut bytes = vec![0; 65535];
        loop {
            let count = unsafe { hy2_read(self.0, bytes.as_mut_ptr(), bytes.len()) };
            if count > 0 {
                bytes.truncate(count as usize);
                return bytes;
            }
            assert!(
                count >= ReadStatus::Empty as i32 && Instant::now() < deadline,
                "TCP packet output timed out"
            );
            thread::sleep(Duration::from_millis(1));
        }
    }
}
/// Releases all packet-engine tasks and its loopback QUIC endpoint.
impl Drop for PacketEngine {
    fn drop(&mut self) {
        unsafe { hy2_stop(self.0) };
    }
}

/// Owns a single loopback TCP responder with bounded blocking reads and writes.
struct Responder {
    address: SocketAddr,
    done: mpsc::Receiver<Result<(), String>>,
    worker: Option<thread::JoinHandle<()>>,
}
/// Starts a byte-validating TCP target with a deterministic binary response.
impl Responder {
    fn start(ipv6: bool, expected: Vec<u8>, response: Vec<u8>) -> Self {
        let listener = TcpListener::bind(if ipv6 { "[::1]:0" } else { "127.0.0.1:0" }).unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let (done, receiver) = mpsc::channel();
        let worker = thread::spawn(move || {
            let run = || -> Result<(), String> {
                let deadline = Instant::now() + support::PHASE_TIMEOUT;
                let mut stream = loop {
                    match listener.accept() {
                        Ok((s, _)) => break s,
                        Err(e)
                            if e.kind() == std::io::ErrorKind::WouldBlock
                                && Instant::now() < deadline =>
                        {
                            thread::sleep(Duration::from_millis(2))
                        }
                        Err(e) => return Err(e.to_string()),
                    }
                };
                stream.set_nonblocking(false).map_err(|e| e.to_string())?;
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .map_err(|e| e.to_string())?;
                stream
                    .set_write_timeout(Some(Duration::from_secs(3)))
                    .map_err(|e| e.to_string())?;
                let mut received = Vec::new();
                stream
                    .read_to_end(&mut received)
                    .map_err(|e| e.to_string())?;
                if received != expected {
                    return Err("upload bytes differed".into());
                }
                stream.write_all(&response).map_err(|e| e.to_string())?;
                Ok(())
            };
            let _ = done.send(run());
        });
        Self {
            address,
            done: receiver,
            worker: Some(worker),
        }
    }
    fn finish(&mut self) {
        self.done
            .recv_timeout(support::PHASE_TIMEOUT)
            .unwrap()
            .unwrap();
        self.worker.take().unwrap().join().unwrap();
    }
}
/// Detaches a still-blocked fixture on panic rather than hanging unwinding indefinitely.
impl Drop for Responder {
    fn drop(&mut self) {
        if self
            .worker
            .as_ref()
            .is_some_and(|worker| worker.is_finished())
        {
            let _ = self.worker.take().unwrap().join();
        }
    }
}

/// Carries both IP families through real QUIC, checking payload followed by half-close in each direction.
#[test]
fn raw_tcp_roundtrips_binary_data_for_both_families() {
    for ipv6 in [false, true] {
        let upload: Vec<u8> = (0..16 * 1024).map(|i| (i % 251) as u8).collect();
        let response: Vec<u8> = (0..256 * 1024).map(|i| (i % 239) as u8).collect();
        let mut target = Responder::start(ipv6, upload.clone(), response.clone());
        let server = support::ServerFixture::start().unwrap();
        let engine = PacketEngine::start(&server);
        let packet = |seq, ack, flags, body: &[u8]| {
            tcp_packets::packet_to(target.address, 32180, seq, ack, flags, body)
        };
        engine.send(packet(100, 0, 2, &[]));
        let syn = engine.receive();
        let h = if ipv6 { 40 } else { 20 };
        assert_eq!(syn[h + 13] & 0x12, 0x12);
        let mut remote = u32::from_be_bytes(syn[h + 4..h + 8].try_into().unwrap()) + 1;
        engine.send(packet(101, remote, 0x10, &[]));
        let mut local = 101;
        for chunk in upload.chunks(1000) {
            engine.send(packet(local, remote, 0x18, chunk));
            local += chunk.len() as u32;
        }
        engine.send(packet(local, remote, 0x11, &[]));
        local += 1;
        let mut received = Vec::new();
        loop {
            let bytes = engine.receive();
            let tcp = h + usize::from(bytes[h + 12] >> 4) * 4;
            let seq = u32::from_be_bytes(bytes[h + 4..h + 8].try_into().unwrap());
            assert_eq!(bytes[h + 13] & 4, 0, "unexpected reset during forwarding");
            if seq != remote {
                continue;
            }
            received.extend_from_slice(&bytes[tcp..]);
            remote += (bytes.len() - tcp) as u32;
            let finished = bytes[h + 13] & 1 != 0;
            if finished {
                remote += 1;
            }
            if bytes.len() > tcp || finished {
                engine.send(packet(local, remote, 0x10, &[]));
            }
            if finished {
                break;
            }
        }
        eprintln!("family_ipv6={ipv6} received_bytes={}", received.len());
        target.finish();
        assert!(
            received == response,
            "TCP response bytes differed for ipv6={ipv6}; received {} bytes",
            received.len()
        );
    }
}
