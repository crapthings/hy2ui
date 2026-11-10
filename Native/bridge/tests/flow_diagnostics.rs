//! Verifies that detailed flow diagnostics classify causes without exposing raw peer text.
use hysteria_cli::desktop_flow_diagnostics::{io_reason, transport_reason};
use hysteria_transport::TransportError;

/// Preserves local error categories and numeric codes without rendering the error string.
#[test]
fn local_error_reasons_are_typed() {
    assert_eq!(io_reason(&std::io::Error::from_raw_os_error(libc::ECONNREFUSED)), ("refused", libc::ECONNREFUSED));
    assert_eq!(io_reason(&std::io::Error::from(std::io::ErrorKind::TimedOut)), ("timeout", 0));
}

/// Differentiates target rejection, address resolution, QUIC failure and disabled UDP relay.
#[test]
fn transport_details_are_allowlisted() {
    assert_eq!(transport_reason(&TransportError::Io("Connection refused (os error 111) secret=discard".into())), ("refused", 111));
    assert_eq!(transport_reason(&TransportError::Protocol("no IPv4 or IPv6 address available".into())), ("dns", 0));
    assert_eq!(transport_reason(&TransportError::Connect("timed out; private config".into())), ("quic_timeout", 0));
    assert_eq!(transport_reason(&TransportError::UdpDisabled), ("udp_disabled", 0));
    assert_eq!(transport_reason(&TransportError::Io("secret peer response".into())), ("io", 0));
}

/// Distinguishes an absent local direct exit from a remote target or server failure.
#[test]
fn absent_local_families_have_specific_reasons() {
    for (ipv6, expected) in [(false, "ipv4_unavailable"), (true, "ipv6_unavailable")] {
        let error = std::io::Error::new(std::io::ErrorKind::NetworkUnreachable,
            hysteria_cli::desktop_routing::DirectEgressUnavailable { ipv6 });
        assert_eq!(io_reason(&error), (expected, 0));
    }
}
