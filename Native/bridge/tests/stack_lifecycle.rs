//! Exercises TCP lifecycle and byte integrity using only in-memory IP packets.
use futures::{FutureExt, SinkExt, StreamExt};
use netstack_smoltcp::{Stack, StackBuilder, TcpListener, TcpStream};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    task::JoinHandle,
    time::{Duration, timeout},
};

/// Shares packet checksums with the real loopback forwarding regression fixture.
#[path = "support/tcp_packets.rs"]
mod tcp_packets;
use tcp_packets::packet;

/// Owns a packet driver and aborts its runner on test completion or panic.
struct Driver {
    ipv6: bool,
    port: u16,
    peer_seq: u32,
    local_seq: u32,
    sink: futures::stream::SplitSink<Stack, Vec<u8>>,
    output: futures::stream::SplitStream<Stack>,
    listener: TcpListener,
    runner: JoinHandle<std::io::Result<()>>,
}

/// Implements bounded handshake and packet exchange phases without opening host sockets.
impl Driver {
    async fn open(ipv6: bool, port: u16) -> (Self, TcpStream) {
        let (stack, runner, _, listener) = StackBuilder::default()
            .enable_tcp(true)
            .tcp_buffer_size(512)
            .mtu(1400)
            .build()
            .unwrap();
        let runner = tokio::spawn(runner.unwrap());
        let (sink, output) = stack.split();
        let mut driver = Self {
            ipv6,
            port,
            peer_seq: 101,
            local_seq: 0,
            sink,
            output,
            listener: listener.unwrap(),
            runner,
        };
        driver.send(100, 0, 2, &[]).await;
        let stream = timeout(Duration::from_secs(5), driver.listener.next())
            .await
            .unwrap()
            .unwrap()
            .0;
        let response = driver.receive().await;
        let h = if ipv6 { 40 } else { 20 };
        assert_eq!(response[h + 13] & 0x12, 0x12);
        driver.local_seq = u32::from_be_bytes(response[h + 4..h + 8].try_into().unwrap()) + 1;
        driver.send(101, driver.local_seq, 0x10, &[]).await;
        (driver, stream)
    }
    async fn send(&mut self, seq: u32, ack: u32, flags: u8, body: &[u8]) {
        timeout(
            Duration::from_secs(5),
            self.sink
                .send(packet(self.ipv6, self.port, seq, ack, flags, body)),
        )
        .await
        .unwrap()
        .unwrap();
    }
    async fn receive(&mut self) -> Vec<u8> {
        timeout(Duration::from_secs(5), self.output.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap()
    }
    async fn response(&mut self) -> Vec<u8> {
        let mut result = Vec::new();
        loop {
            let packet = self.receive().await;
            let h = if self.ipv6 { 40 } else { 20 };
            let seq = u32::from_be_bytes(packet[h + 4..h + 8].try_into().unwrap());
            let flags = packet[h + 13];
            assert_eq!(flags & 4, 0, "unexpected reset");
            let body = &packet[h + usize::from(packet[h + 12] >> 4) * 4..];
            if seq != self.local_seq {
                continue;
            }
            result.extend_from_slice(body);
            self.local_seq += body.len() as u32;
            if flags & 1 != 0 {
                self.local_seq += 1;
            }
            if !body.is_empty() || flags & 1 != 0 {
                self.send(self.peer_seq, self.local_seq, 0x10, &[]).await;
            }
            if flags & 1 != 0 {
                return result;
            }
        }
    }
}

/// Cancels only the in-memory stack runner owned by this fixture.
impl Drop for Driver {
    fn drop(&mut self) {
        self.runner.abort();
    }
}

/// Confirms retransmitted SYN packets are processed without creating another accepted stream.
#[tokio::test]
async fn repeated_syn_is_deduplicated_in_both_families() {
    for ipv6 in [false, true] {
        let (mut driver, mut stream) = Driver::open(ipv6, 32123).await;
        for _ in 0..10 {
            driver.send(100, 0, 2, &[]).await;
        }
        driver.send(101, driver.local_seq, 0x18, b"barrier").await;
        let mut read = [0; 7];
        timeout(Duration::from_secs(5), stream.read_exact(&mut read))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&read, b"barrier");
        assert!(
            driver.listener.next().now_or_never().is_none(),
            "duplicate stream escaped"
        );
    }
}

/// Preserves queued response bytes when the client half-closes before a large server response.
#[tokio::test]
async fn client_first_fin_flushes_large_response_without_timewait_blocking() {
    for ipv6 in [false, true] {
        let (mut driver, mut stream) = Driver::open(ipv6, 32124).await;
        driver.send(101, driver.local_seq, 0x11, &[]).await;
        driver.peer_seq += 1;
        let mut eof = [0; 1];
        assert_eq!(
            timeout(Duration::from_secs(5), stream.read(&mut eof))
                .await
                .unwrap()
                .unwrap(),
            0
        );
        let expected: Vec<u8> = (0..256 * 1024).map(|i| (i % 251) as u8).collect();
        let body = expected.clone();
        let writer = tokio::spawn(async move {
            stream.write_all(&body).await.unwrap();
            stream.shutdown().await.unwrap();
        });
        let actual = driver.response().await;
        timeout(Duration::from_secs(5), writer)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(actual, expected);
    }
}

/// Completes server write shutdown while leaving the client's upload direction usable.
#[tokio::test]
async fn server_first_fin_keeps_read_half_open() {
    for ipv6 in [false, true] {
        let (mut driver, mut stream) = Driver::open(ipv6, 32125).await;
        let closing = tokio::spawn(async move {
            stream.write_all(b"reply").await.unwrap();
            stream.shutdown().await.unwrap();
            stream
        });
        assert_eq!(driver.response().await, b"reply");
        let mut stream = timeout(Duration::from_secs(5), closing)
            .await
            .unwrap()
            .unwrap();
        driver.send(101, driver.local_seq, 0x18, b"upload").await;
        let mut body = [0; 6];
        timeout(Duration::from_secs(5), stream.read_exact(&mut body))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&body, b"upload");
        driver.send(107, driver.local_seq, 0x11, &[]).await;
        let mut eof = [0; 1];
        assert_eq!(
            timeout(Duration::from_secs(5), stream.read(&mut eof))
                .await
                .unwrap()
                .unwrap(),
            0
        );
    }
}

/// Resets abandoned streams instead of leaving an accepted socket alive for its two-hour timeout.
#[tokio::test]
async fn dropping_unfinished_stream_emits_reset() {
    let (mut driver, stream) = Driver::open(false, 32126).await;
    drop(stream);
    loop {
        let packet = driver.receive().await;
        if packet[33] & 4 != 0 {
            break;
        }
    }
}

/// Reuses one tuple beyond the socket limit to prove aborted sockets release their tuple leases promptly.
#[tokio::test]
async fn aborted_tuple_can_be_reused_after_connection_churn() {
    let (mut driver, stream) = Driver::open(false, 32127).await;
    drop(stream);
    for _ in 0..1028 {
        loop {
            let packet = driver.receive().await;
            if packet[33] & 4 != 0 {
                break;
            }
        }
        driver.send(100, 0, 2, &[]).await;
        let stream = timeout(Duration::from_secs(5), driver.listener.next())
            .await
            .unwrap()
            .unwrap()
            .0;
        loop {
            let packet = driver.receive().await;
            if packet[33] & 0x12 == 0x12 {
                driver.local_seq = u32::from_be_bytes(packet[24..28].try_into().unwrap()) + 1;
                break;
            }
        }
        driver.send(101, driver.local_seq, 0x10, &[]).await;
        drop(stream);
    }
}
