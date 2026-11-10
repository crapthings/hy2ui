//! Verifies packet forwarding through loopback-only fixtures without modifying host networking.
use hy2_bridge::{
    Engine, EngineState, ReadStatus, WriteResult, hy2_error, hy2_read, hy2_start, hy2_state,
    hy2_stop, hy2_write,
};
use std::{
    ptr, thread,
    time::{Duration, Instant},
};

/// Provides readiness-aware loopback server and echo fixtures with bounded teardown.
mod support;
use support::{EchoFixture, PHASE_TIMEOUT, ServerFixture};

/// Stops a native engine exactly once when the test scope exits or unwinds.
struct EngineGuard(*mut Engine);

/// Provides bounded packet-engine operations for the loopback integration test.
impl EngineGuard {
    /// Starts a packet engine and gives its handshake a fresh independent timeout budget.
    fn connect(server: &ServerFixture) -> Self {
        let json = serde_json::to_vec(&serde_json::json!({
            "server": server.address.to_string(), "auth": "test-password",
            "tls": {"sni": "localhost", "insecure": true, "pinSHA256": server.certificate_pin}
        }))
        .unwrap();
        let mut error = [0u8; 2048];
        let engine = Self(unsafe {
            hy2_start(
                json.as_ptr(),
                json.len(),
                1400,
                error.as_mut_ptr(),
                error.len(),
            )
        });
        assert!(!engine.0.is_null(), "{}", String::from_utf8_lossy(&error));
        let deadline = Instant::now() + PHASE_TIMEOUT;
        while unsafe { hy2_state(engine.0) } == EngineState::Connecting && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(
            unsafe { hy2_state(engine.0) },
            EngineState::Connected,
            "{}",
            engine.error()
        );
        engine
    }

    /// Returns an engine error without assuming the caller-provided buffer is fully filled.
    fn error(&self) -> String {
        let mut error = [0u8; 2048];
        let count = unsafe { hy2_error(self.0, error.as_mut_ptr(), error.len()) };
        String::from_utf8_lossy(&error[..count]).into_owned()
    }

    /// Sends one packet while bounding queue backpressure with its own timeout budget.
    fn send(&self, packet: &[u8]) {
        let deadline = Instant::now() + PHASE_TIMEOUT;
        loop {
            match unsafe { hy2_write(self.0, packet.as_ptr(), packet.len()) } {
                WriteResult::Accepted => return,
                WriteResult::Full if Instant::now() < deadline => {
                    thread::sleep(Duration::from_millis(5))
                }
                other => panic!("packet send failed: {other:?}: {}", self.error()),
            }
        }
    }

    /// Waits for a UDP response using a timeout budget separate from server startup and handshake.
    fn receive_udp(&self) -> Vec<u8> {
        let deadline = Instant::now() + PHASE_TIMEOUT;
        let mut output = [0u8; 65535];
        loop {
            let count = unsafe { hy2_read(self.0, output.as_mut_ptr(), output.len()) };
            if (count >= 28 && output[0] >> 4 == 4 && output[9] == 17)
                || (count >= 48 && output[0] >> 4 == 6 && output[6] == 17)
            {
                return output[..count as usize].to_vec();
            }
            assert!(
                count >= ReadStatus::Empty as i32,
                "packet read failed: {}",
                self.error()
            );
            assert_eq!(
                unsafe { hy2_state(self.0) },
                EngineState::Connected,
                "{}",
                self.error()
            );
            assert!(Instant::now() < deadline, "UDP roundtrip timed out");
            thread::sleep(Duration::from_millis(5));
        }
    }
}

/// Releases the native engine when a test returns or unwinds.
impl Drop for EngineGuard {
    /// Joins the native worker after requesting cooperative engine shutdown.
    fn drop(&mut self) {
        unsafe { hy2_stop(self.0) };
    }
}

/// Builds a checksummed IPv4 UDP packet addressed to the fixture echo port.
fn udp_packet(echo_port: u16, payload: &[u8]) -> Vec<u8> {
    let length = 28 + payload.len();
    let mut packet = vec![0u8; length];
    packet[0] = 0x45;
    packet[2..4].copy_from_slice(&(length as u16).to_be_bytes());
    packet[8] = 64;
    packet[9] = 17;
    packet[12..16].copy_from_slice(&[198, 18, 0, 2]);
    packet[16..20].copy_from_slice(&[127, 0, 0, 1]);
    let sum: u32 = packet[..20]
        .chunks_exact(2)
        .map(|p| u16::from_be_bytes([p[0], p[1]]) as u32)
        .sum();
    let checksum = !(((sum & 0xffff) + (sum >> 16)) as u16);
    packet[10..12].copy_from_slice(&checksum.to_be_bytes());
    packet[20..22].copy_from_slice(&45678u16.to_be_bytes());
    packet[22..24].copy_from_slice(&echo_port.to_be_bytes());
    packet[24..26].copy_from_slice(&((8 + payload.len()) as u16).to_be_bytes());
    packet[28..].copy_from_slice(payload);
    packet
}

/// Verifies a raw UDP packet traverses the userspace stack and real Hysteria connection both ways.
#[test]
fn raw_ipv4_udp_packet_roundtrips_through_hysteria() {
    let mut server = ServerFixture::start().expect("loopback Hysteria server readiness");
    let mut echo = EchoFixture::start().expect("loopback echo socket");
    let engine = EngineGuard::connect(&server);
    let payload = b"hy2-packet-roundtrip";
    engine.send(&udp_packet(echo.port, payload));
    let output = engine.receive_udp();
    let header = usize::from(output[0] & 15) * 4;
    assert_eq!(&output[header + 8..], payload);
    assert_eq!(&output[16..20], &[198, 18, 0, 2]);
    drop(engine);
    echo.finish().expect("echo fixture shutdown");
    server.finish().expect("server fixture shutdown");
    assert_eq!(unsafe { hy2_state(ptr::null()) }, EngineState::Failed);
}

/// Builds an IPv6 UDP packet with the mandatory pseudo-header checksum for the echo fixture.
fn ipv6_udp_packet(echo_port: u16, payload: &[u8]) -> Vec<u8> {
    let source: std::net::Ipv6Addr = "fd72:6832::2".parse().unwrap();
    let destination = std::net::Ipv6Addr::LOCALHOST;
    let udp_length = (8 + payload.len()) as u16;
    let mut packet = vec![0u8; 40 + usize::from(udp_length)];
    packet[0] = 0x60;
    packet[4..6].copy_from_slice(&udp_length.to_be_bytes());
    packet[6] = 17;
    packet[7] = 64;
    packet[8..24].copy_from_slice(&source.octets());
    packet[24..40].copy_from_slice(&destination.octets());
    packet[40..42].copy_from_slice(&45678u16.to_be_bytes());
    packet[42..44].copy_from_slice(&echo_port.to_be_bytes());
    packet[44..46].copy_from_slice(&udp_length.to_be_bytes());
    packet[48..].copy_from_slice(payload);
    let mut pseudo = packet[8..40].to_vec();
    pseudo.extend_from_slice(&u32::from(udp_length).to_be_bytes());
    pseudo.extend_from_slice(&[0, 0, 0, 17]);
    pseudo.extend_from_slice(&packet[40..]);
    if pseudo.len() % 2 != 0 {
        pseudo.push(0);
    }
    let mut sum: u32 = pseudo
        .chunks_exact(2)
        .map(|bytes| u32::from(u16::from_be_bytes([bytes[0], bytes[1]])))
        .sum();
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    let checksum = !(sum as u16);
    let checksum = if checksum == 0 { u16::MAX } else { checksum };
    packet[46..48].copy_from_slice(&checksum.to_be_bytes());
    packet
}

/// Sends raw IPv6 UDP packets over an IPv4 Hysteria transport without creating a system TUN interface.
#[test]
fn raw_ipv6_udp_packet_roundtrips_over_ipv4_hysteria() {
    let mut server = ServerFixture::start().expect("loopback Hysteria server readiness");
    let mut echo = EchoFixture::start_ipv6().expect("IPv6 loopback echo socket");
    let engine = EngineGuard::connect(&server);
    let payload = b"hy2-ipv6-packet-roundtrip";
    engine.send(&ipv6_udp_packet(echo.port, payload));
    let output = engine.receive_udp();
    assert_eq!(output[0] >> 4, 6);
    assert_eq!(&output[48..], payload);
    let source: std::net::Ipv6Addr = "fd72:6832::2".parse().unwrap();
    assert_eq!(&output[24..40], &source.octets());
    drop(engine);
    echo.finish().expect("IPv6 echo fixture shutdown");
    server.finish().expect("server fixture shutdown");
}
