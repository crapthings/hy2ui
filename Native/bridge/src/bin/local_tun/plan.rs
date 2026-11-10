//! Builds fixed TUN routes from validated input without allowing callers to supply privileged options.
use super::configuration::LocalTunConfiguration;
use hysteria_cli::config::ClientConfig;
use std::{ffi::CString, net::SocketAddr};

/// Holds the immutable core settings for one privileged TUN session.
pub struct TunPlan {
    pub config: ClientConfig,
}

/// Converts a frozen endpoint into a TCP/UDP-only TUN configuration with a physical host-route bypass.
impl TunPlan {
    pub fn build(
        input: &LocalTunConfiguration,
        endpoint: SocketAddr,
        interface_name: &str,
    ) -> Result<Self, String> {
        input.validate()?;
        if endpoint.port() != input.port || !valid_interface_name(interface_name) {
            return Err("invalid frozen local TUN endpoint or interface".into());
        }
        let tls_name = if input.server_name.is_empty() {
            &input.host
        } else {
            &input.server_name
        };
        let exclusion = format!(
            "{}/{}",
            endpoint.ip(),
            if endpoint.is_ipv4() { 32 } else { 128 }
        );
        let mut value = serde_json::json!({
            "server": endpoint.to_string(), "auth": input.password,
            "lazy": false, "tls": {"sni": tls_name},
            "tun": {
                "name": interface_name, "mtu": input.mtu, "timeout": "60s",
                "address": {"ipv4": "198.18.0.1/30", "ipv6": "fd72:6832::1/126"},
                "route": {
                    "strict": false,
                    "ipv4": ["0.0.0.0/1", "128.0.0.0/1"],
                    "ipv6": ["::/1", "8000::/1"],
                    "ipv4Exclude": if endpoint.is_ipv4() { vec![exclusion.clone()] } else { vec![] },
                    "ipv6Exclude": if endpoint.is_ipv6() { vec![exclusion] } else { vec![] }
                }
            }
        });
        if !input.obfuscation_password.is_empty() {
            value["obfs"] = serde_json::json!({"type": "salamander", "salamander": {"password": input.obfuscation_password}});
        }
        let config: ClientConfig = serde_json::from_value(value)
            .map_err(|_| "failed to build fixed local TUN configuration".to_string())?;
        config
            .validate()
            .map_err(|_| "local TUN configuration failed core validation".to_string())?;
        Ok(Self { config })
    }
}

/// Selects a free numeric utun name without creating or modifying any network interface.
pub fn available_interface_name() -> Result<String, String> {
    select_interface_name(std::process::id(), |name| {
        let Ok(name) = CString::new(name) else {
            return false;
        };
        // SAFETY: name is a NUL-terminated string valid for this synchronous lookup.
        unsafe { libc::if_nametoindex(name.as_ptr()) == 0 }
    })
}

/// Scans a bounded PID-derived range so an occupied name fails safely rather than replacing an interface.
fn select_interface_name(
    process_id: u32,
    available: impl Fn(&str) -> bool,
) -> Result<String, String> {
    let start = 100 + process_id % 10_000;
    (start..start + 64)
        .map(|index| format!("utun{index}"))
        .find(|name| available(name))
        .ok_or_else(|| "no unused local TUN interface name is available".into())
}

/// Restricts interface selection to internally generated numeric macOS utun identifiers.
fn valid_interface_name(name: &str) -> bool {
    name.strip_prefix("utun").is_some_and(|suffix| {
        !suffix.is_empty() && suffix.len() <= 5 && suffix.bytes().all(|byte| byte.is_ascii_digit())
    })
}

/// Verifies route planning and address freezing without invoking the privileged core runtime.
#[cfg(test)]
mod tests {
    use super::*;

    /// Creates a validated input from a pure in-memory fixture.
    fn sample() -> LocalTunConfiguration {
        serde_json::from_value(serde_json::json!({
            "host": "vpn.example.com", "port": 443, "serverName": "tls.example.com",
            "password": "test-password", "obfuscationPassword": "obfs-test", "mtu": 1400,
            "dns": ["1.1.1.1"]
        }))
        .unwrap()
    }

    /// Pins the server to IPv4 and adds its bypass before the split default routes.
    #[test]
    fn creates_ipv4_host_bypass_without_privileged_listeners() {
        let plan =
            TunPlan::build(&sample(), "203.0.113.8:443".parse().unwrap(), "utun4242").unwrap();
        assert_eq!(plan.config.server, "203.0.113.8:443");
        assert_eq!(plan.config.tls.sni, "tls.example.com");
        assert!(plan.config.socks5.is_none() && plan.config.http.is_none());
        assert!(plan.config.tcp_forwarding.is_empty() && plan.config.udp_forwarding.is_empty());
        assert!(
            plan.config.tcp_redirect.is_none()
                && plan.config.tcp_tproxy.is_none()
                && plan.config.udp_tproxy.is_none()
        );
        let tun = plan.config.tun.unwrap();
        assert_eq!(tun.address.ipv4, "198.18.0.1/30");
        let routes = tun.route.unwrap();
        assert_eq!(routes.ipv4_exclude, ["203.0.113.8/32"]);
        assert!(routes.ipv6_exclude.is_empty());
        assert_eq!(routes.ipv4, ["0.0.0.0/1", "128.0.0.0/1"]);
        assert_eq!(routes.ipv6, ["::/1", "8000::/1"]);
    }

    /// Pins IPv6 servers while retaining hostname-based TLS identity and optional obfuscation.
    #[test]
    fn creates_ipv6_host_bypass_and_retains_tls_and_obfuscation() {
        let mut input = sample();
        input.server_name.clear();
        let plan =
            TunPlan::build(&input, "[2001:db8::8]:443".parse().unwrap(), "utun4243").unwrap();
        assert_eq!(plan.config.server, "[2001:db8::8]:443");
        assert_eq!(plan.config.tls.sni, "vpn.example.com");
        assert!(!plan.config.tls.insecure && plan.config.tls.ca.is_empty());
        assert_eq!(plan.config.obfs.kind, "salamander");
        assert_eq!(plan.config.obfs.salamander.password, "obfs-test");
        let route = plan.config.tun.unwrap().route.unwrap();
        assert_eq!(route.ipv6_exclude, ["2001:db8::8/128"]);
        assert!(route.ipv4_exclude.is_empty());
    }

    /// Selects around occupied names and bounds failure when no candidate is available.
    #[test]
    fn selects_only_an_unused_numeric_interface() {
        assert_eq!(
            select_interface_name(42, |name| name == "utun145").unwrap(),
            "utun145"
        );
        assert!(select_interface_name(42, |_| false).is_err());
        assert!(
            !valid_interface_name("utun")
                && !valid_interface_name("en0")
                && !valid_interface_name("utun1;command")
        );
        assert!(TunPlan::build(&sample(), "203.0.113.8:444".parse().unwrap(), "utun4242").is_err());
    }
}
