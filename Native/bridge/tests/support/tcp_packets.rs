//! Builds valid synthetic TCP packets for the in-memory and loopback forwarding fixtures.
/// Computes one's-complement checksums for the synthetic IP and TCP headers.
fn checksum(bytes: &[u8]) -> u16 {
    let mut sum: u32 = bytes
        .chunks(2)
        .map(|part| ((part[0] as u32) << 8) | part.get(1).copied().unwrap_or(0) as u32)
        .sum();
    while sum > 0xffff {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    !(sum as u16)
}

/// Builds a synthetic packet with valid IPv4 or IPv6 TCP checksums and a fixed advertised window.
pub fn packet(ipv6: bool, port: u16, seq: u32, ack: u32, flags: u8, body: &[u8]) -> Vec<u8> {
    packet_to(
        if ipv6 {
            "[2001:db8::1]:443"
        } else {
            "203.0.113.1:443"
        }
        .parse()
        .unwrap(),
        port,
        seq,
        ack,
        flags,
        body,
    )
}

/// Builds an IP packet for an explicitly provided destination without sending it through host routes.
pub fn packet_to(
    destination: std::net::SocketAddr,
    port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    body: &[u8],
) -> Vec<u8> {
    let ipv6 = destination.is_ipv6();
    let header = if ipv6 { 40 } else { 20 };
    let mut bytes = vec![0u8; header + 20 + body.len()];
    if ipv6 {
        bytes[0] = 0x60;
        bytes[4..6].copy_from_slice(&((20 + body.len()) as u16).to_be_bytes());
        bytes[6] = 6;
        bytes[7] = 64;
        bytes[8..24].copy_from_slice(&"fd00::2".parse::<std::net::Ipv6Addr>().unwrap().octets());
        let std::net::IpAddr::V6(ip) = destination.ip() else {
            unreachable!()
        };
        bytes[24..40].copy_from_slice(&ip.octets());
    } else {
        bytes[0] = 0x45;
        let size = bytes.len() as u16;
        bytes[2..4].copy_from_slice(&size.to_be_bytes());
        bytes[8] = 64;
        bytes[9] = 6;
        bytes[12..16].copy_from_slice(&[10, 0, 0, 2]);
        let std::net::IpAddr::V4(ip) = destination.ip() else {
            unreachable!()
        };
        bytes[16..20].copy_from_slice(&ip.octets());
    }
    let tcp = &mut bytes[header..];
    tcp[..2].copy_from_slice(&port.to_be_bytes());
    tcp[2..4].copy_from_slice(&destination.port().to_be_bytes());
    tcp[4..8].copy_from_slice(&seq.to_be_bytes());
    tcp[8..12].copy_from_slice(&ack.to_be_bytes());
    tcp[12] = 0x50;
    tcp[13] = flags;
    tcp[14..16].copy_from_slice(&65535u16.to_be_bytes());
    tcp[20..].copy_from_slice(body);
    let mut pseudo = if ipv6 {
        bytes[8..40].to_vec()
    } else {
        bytes[12..20].to_vec()
    };
    if ipv6 {
        pseudo.extend_from_slice(&((20 + body.len()) as u32).to_be_bytes());
        pseudo.extend_from_slice(&[0, 0, 0, 6]);
    } else {
        pseudo.extend_from_slice(&[0, 6]);
        pseudo.extend_from_slice(&((20 + body.len()) as u16).to_be_bytes());
    }
    pseudo.extend_from_slice(&bytes[header..]);
    let value = checksum(&pseudo);
    bytes[header + 16..header + 18].copy_from_slice(&value.to_be_bytes());
    if !ipv6 {
        let value = checksum(&bytes[..20]);
        bytes[10..12].copy_from_slice(&value.to_be_bytes());
    }
    bytes
}
