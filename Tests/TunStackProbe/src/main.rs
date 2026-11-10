//! Probes TCP stream creation and shutdown using synthetic IP packets without touching host networking.
use futures::{SinkExt, StreamExt};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    time::{Duration, timeout},
};

/// Computes an Internet checksum for the synthetic TCP and IPv4 headers.
fn checksum(bytes: &[u8]) -> u16 {
    let mut sum: u32 = bytes
        .chunks(2)
        .map(|c| ((c[0] as u32) << 8) | (c.get(1).copied().unwrap_or(0) as u32))
        .sum();
    while sum > 0xffff {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}
/// Builds one in-memory test packet with fixed documentation-only destination addresses.
fn packet(seq: u32, ack: u32, flags: u8, payload: &[u8]) -> Vec<u8> {
    let mut p = vec![0; 40 + payload.len()];
    p[0] = 0x45;
    let len = p.len() as u16;
    p[2..4].copy_from_slice(&len.to_be_bytes());
    p[8] = 64;
    p[9] = 6;
    p[12..16].copy_from_slice(&[10, 0, 0, 2]);
    p[16..20].copy_from_slice(&[203, 0, 113, 1]);
    p[20..22].copy_from_slice(&32123u16.to_be_bytes());
    p[22..24].copy_from_slice(&443u16.to_be_bytes());
    p[24..28].copy_from_slice(&seq.to_be_bytes());
    p[28..32].copy_from_slice(&ack.to_be_bytes());
    p[32] = 0x50;
    p[33] = flags;
    p[34..36].copy_from_slice(&65535u16.to_be_bytes());
    p[40..].copy_from_slice(payload);
    let mut pseudo = p[12..20].to_vec();
    pseudo.extend_from_slice(&[0, 6]);
    pseudo.extend_from_slice(&((p.len() - 20) as u16).to_be_bytes());
    pseudo.extend_from_slice(&p[20..]);
    let c = checksum(&pseudo);
    p[36..38].copy_from_slice(&c.to_be_bytes());
    let c = checksum(&p[..20]);
    p[10..12].copy_from_slice(&c.to_be_bytes());
    p
}
/// Measures retransmitted SYN handling and half-close completion in the pinned TCP stack.
#[tokio::main(flavor = "current_thread")]
async fn main() {
    let (stack, runner, _, listener) = netstack_smoltcp::StackBuilder::default()
        .enable_tcp(true)
        .mtu(1400)
        .build()
        .unwrap();
    let task = tokio::spawn(runner.unwrap());
    let (mut sink, mut output) = stack.split();
    let mut listener = listener.unwrap();
    sink.send(packet(100, 0, 2, &[])).await.unwrap();
    let mut stream = timeout(Duration::from_secs(2), listener.next())
        .await
        .unwrap()
        .unwrap()
        .0;
    let response = timeout(Duration::from_secs(2), output.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let seq = u32::from_be_bytes(response[24..28].try_into().unwrap());
    sink.send(packet(100, 0, 2, &[])).await.unwrap();
    let duplicated = timeout(Duration::from_millis(100), listener.next())
        .await
        .ok()
        .flatten();
    println!(
        "retransmitted SYN creates extra accepted stream: {}",
        duplicated.is_some()
    );
    let mut duplicate_count = usize::from(duplicated.is_some());
    let mut extra = Vec::new();
    for _ in 0..9 {
        sink.send(packet(100, 0, 2, &[])).await.unwrap();
        if let Ok(Some(stream)) = timeout(Duration::from_millis(100), listener.next()).await {
            duplicate_count += 1;
            extra.push(stream);
        }
    }
    println!(
        "extra accepted streams after 10 identical SYN retransmissions: {}",
        duplicate_count
    );
    drop(duplicated);
    drop(extra);
    sink.send(packet(101, seq + 1, 0x10, &[])).await.unwrap();
    sink.send(packet(101, seq + 1, 0x18, b"hello"))
        .await
        .unwrap();
    let mut buf = [0; 5];
    let readable = timeout(Duration::from_millis(300), stream.read_exact(&mut buf)).await;
    println!(
        "original stream readable after duplicate SYN: {:?}",
        readable
    );
    task.abort();
    let _ = task.await;
    let (stack, runner, _, listener) = netstack_smoltcp::StackBuilder::default()
        .enable_tcp(true)
        .mtu(1400)
        .build()
        .unwrap();
    let task = tokio::spawn(runner.unwrap());
    let (mut sink, mut output) = stack.split();
    let mut listener = listener.unwrap();
    sink.send(packet(100, 0, 2, &[])).await.unwrap();
    let mut stream = timeout(Duration::from_secs(2), listener.next())
        .await
        .unwrap()
        .unwrap()
        .0;
    let response = timeout(Duration::from_secs(2), output.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let seq = u32::from_be_bytes(response[24..28].try_into().unwrap());
    sink.send(packet(101, seq + 1, 0x10, &[])).await.unwrap();
    let shutdown = tokio::spawn(async move {
        let result = stream.shutdown().await;
        (stream, result)
    });
    let fin = loop {
        let p = timeout(Duration::from_secs(2), output.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if p[33] & 1 != 0 {
            break p;
        }
    };
    let finseq = u32::from_be_bytes(fin[24..28].try_into().unwrap());
    sink.send(packet(101, finseq + 1, 0x10, &[])).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    println!(
        "write shutdown completed after FIN acknowledged: {}",
        shutdown.is_finished()
    );
    sink.send(packet(101, finseq + 1, 0x11, &[])).await.unwrap();
    tokio::time::sleep(Duration::from_millis(100)).await;
    println!(
        "write shutdown completed after both peers closed: {}",
        shutdown.is_finished()
    );
    let started = std::time::Instant::now();
    match timeout(Duration::from_secs(12), shutdown).await {
        Ok(Ok((_stream, result))) => println!(
            "shutdown completion after both FINs: {:?}, additional wait {:.2}s",
            result,
            started.elapsed().as_secs_f64()
        ),
        Ok(Err(error)) => panic!("shutdown task failed: {error}"),
        Err(_) => println!("shutdown still pending after 12 seconds"),
    }
    task.abort();
    let _ = task.await;
}
