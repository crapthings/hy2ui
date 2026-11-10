//! Classifies flow failures into fixed tokens without forwarding secrets or arbitrary server messages.
use hysteria_transport::TransportError;

/// Extracts bounded OS error numbers from known formatting without retaining the source message.
fn os_code(message: &str) -> i32 {
    message.rsplit_once("(os error ").and_then(|(_, tail)| tail.split(')').next())
        .and_then(|number| number.parse::<i32>().ok()).filter(|code| (0..=65535).contains(code)).unwrap_or(0)
}

/// Recognizes specific human-readable causes while discarding all unrecognized message content.
fn message_reason(message: &str) -> Option<&'static str> {
    let text: String = message.chars().take(1024).flat_map(char::to_lowercase).collect();
    if text.contains("no ipv4 or ipv6 address") || text.contains("dns") || text.contains("name or service not known") || text.contains("nodename nor servname") { Some("dns") }
    else if text.contains("connection refused") { Some("refused") }
    else if text.contains("network is unreachable") || text.contains("network unreachable") { Some("network_unreachable") }
    else if text.contains("no route to host") || text.contains("host is unreachable") { Some("host_unreachable") }
    else if text.contains("timed out") || text.contains("timeout") { Some("timeout") }
    else if text.contains("reset") { Some("reset") }
    else if text.contains("broken pipe") { Some("broken_pipe") }
    else if text.contains("permission denied") || text.contains("operation not permitted") { Some("permission") }
    else if text.contains("cannot assign requested address") || text.contains("address not available") { Some("address_unavailable") }
    else { None }
}

/// Preserves typed local I/O causes and their numeric code without logging error text.
pub fn io_reason(error: &std::io::Error) -> (&'static str, i32) {
    use std::io::ErrorKind;
    if let Some(missing) = error.get_ref().and_then(|cause| cause.downcast_ref::<crate::desktop_routing::DirectEgressUnavailable>()) {
        return (if missing.ipv6 { "ipv6_unavailable" } else { "ipv4_unavailable" }, 0);
    }
    let reason = match error.kind() {
        ErrorKind::TimedOut => "timeout", ErrorKind::ConnectionRefused => "refused",
        ErrorKind::NetworkUnreachable => "network_unreachable", ErrorKind::HostUnreachable => "host_unreachable",
        ErrorKind::ConnectionReset | ErrorKind::ConnectionAborted => "reset", ErrorKind::BrokenPipe => "broken_pipe",
        ErrorKind::UnexpectedEof => "unexpected_eof", ErrorKind::PermissionDenied => "permission",
        ErrorKind::AddrNotAvailable => "address_unavailable", _ => "io",
    };
    (reason, error.raw_os_error().filter(|code| (0..=65535).contains(code)).unwrap_or(0))
}

/// Keeps transport-layer failures distinct from target-side dial errors using fixed reason tokens.
pub fn transport_reason(error: &TransportError) -> (&'static str, i32) {
    match error {
        TransportError::Io(message) => (message_reason(message).unwrap_or("io"), os_code(message)),
        TransportError::Protocol(message) => (message_reason(message).unwrap_or("protocol_error"), os_code(message)),
        TransportError::Connect(message) => (if message_reason(message) == Some("timeout") { "quic_timeout" } else { "quic_connect" }, os_code(message)),
        TransportError::Endpoint(message) => ("quic_connect", os_code(message)),
        TransportError::AuthenticationFailed(_) => ("authentication", 0),
        TransportError::UdpDisabled => ("udp_disabled", 0), TransportError::DatagramTooLarge(_) => ("datagram_too_large", 0),
        TransportError::SessionClosed => ("session_closed", 0), TransportError::Closed => ("closed", 0),
        _ => ("protocol_error", 0),
    }
}
