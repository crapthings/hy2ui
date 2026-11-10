//! Validates the narrow privileged-worker input without accepting arbitrary core configuration.
use serde::Deserialize;
use std::{io::Read, net::IpAddr};

/// Limits how much configuration a privileged worker will read from its private stdin pipe.
pub const MAX_CONFIGURATION_BYTES: u64 = 1_048_576;

/// Carries only the endpoint, secrets, and networking settings accepted by the local helper.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LocalTunConfiguration {
    pub host: String,
    pub port: u16,
    pub server_name: String,
    pub password: String,
    pub obfuscation_password: String,
    pub mtu: u16,
    pub dns: Vec<String>,
    #[serde(default)]
    pub direct_processes: Vec<String>,
}

/// Reads one bounded JSON message and rejects unsupported fields without echoing secrets.
pub fn read_configuration(reader: impl Read) -> Result<LocalTunConfiguration, String> {
    let mut bytes = Vec::new();
    reader
        .take(MAX_CONFIGURATION_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "failed to read local TUN configuration".to_string())?;
    if bytes.is_empty() || bytes.len() as u64 > MAX_CONFIGURATION_BYTES {
        return Err("invalid local TUN configuration size".into());
    }
    let config: LocalTunConfiguration = serde_json::from_slice(&bytes)
        .map_err(|_| "invalid local TUN configuration".to_string())?;
    config.validate()?;
    Ok(config)
}

/// Enforces the endpoint and network boundaries before any privileged operation is attempted.
impl LocalTunConfiguration {
    pub fn validate(&self) -> Result<(), String> {
        if self.direct_processes.len() > 64 || self.direct_processes.iter().any(|p| p.is_empty() || p.len() > 1024 || p.chars().any(char::is_control)) {
            return Err("invalid application routing patterns".into());
        }

        if !valid_host(&self.host)
            || (!self.server_name.is_empty() && !valid_host(&self.server_name))
        {
            return Err("invalid local TUN server address or TLS name".into());
        }
        if self.port == 0 || !(1280..=1500).contains(&self.mtu) {
            return Err("invalid local TUN port or MTU".into());
        }
        if self.password.is_empty()
            || self.password.len() > 4096
            || self.obfuscation_password.len() > 4096
        {
            return Err("invalid local TUN credential size".into());
        }
        if self.dns.is_empty()
            || self.dns.len() > 8
            || self
                .dns
                .iter()
                .any(|value| value.parse::<IpAddr>().is_err())
        {
            return Err("invalid local TUN DNS addresses".into());
        }
        Ok(())
    }
}

/// Accepts plain IP literals or DNS labels while excluding URI, zone, path, and option syntax.
fn valid_host(host: &str) -> bool {
    if host.is_empty() || host.len() > 253 || !host.is_ascii() {
        return false;
    }
    if host.parse::<IpAddr>().is_ok() {
        return true;
    }
    let name = host.strip_suffix('.').unwrap_or(host);
    !name.is_empty()
        && name.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
}

/// Exercises the privileged input boundary with data only, never creating interfaces or routes.
#[cfg(test)]
mod tests {
    use super::*;

    /// Produces one valid configuration without using real authentication material.
    pub fn sample_value() -> serde_json::Value {
        serde_json::json!({
            "host": "vpn.example.com", "port": 443, "serverName": "vpn.example.com",
            "password": "test-password", "obfuscationPassword": "", "mtu": 1400,
            "dns": ["1.1.1.1", "2606:4700:4700::1111"]
        })
    }

    /// Rejects core fields that could expose root-readable file paths or enable extra listeners.
    #[test]
    fn rejects_unknown_privileged_options() {
        for (key, value) in [
            ("tls", serde_json::json!({"ca": "/etc/private"})),
            ("http", serde_json::json!({"listen": "0.0.0.0:8080"})),
            ("tun", serde_json::json!({"name": "utun1"})),
        ] {
            let mut object = sample_value();
            object[key] = value;
            let bytes = serde_json::to_vec(&object).unwrap();
            assert!(read_configuration(bytes.as_slice()).is_err());
        }
    }

    /// Rejects malformed addresses, network settings, and empty credentials before root work begins.
    #[test]
    fn rejects_invalid_networking_fields() {
        for host in [
            "realm:secret",
            "https://example.com",
            "example.com:443",
            "../example",
            "a b",
            "[::1]",
            "fe80::1%en0",
            "-bad.example",
        ] {
            let mut object = sample_value();
            object["host"] = host.into();
            assert!(read_configuration(serde_json::to_vec(&object).unwrap().as_slice()).is_err());
        }
        for (key, value) in [
            ("port", serde_json::json!(0)),
            ("port", serde_json::json!(65536)),
            ("mtu", serde_json::json!(1279)),
            ("password", serde_json::json!("")),
            ("dns", serde_json::json!(["not-an-ip"])),
            ("dns", serde_json::json!([])),
        ] {
            let mut object = sample_value();
            object[key] = value;
            assert!(read_configuration(serde_json::to_vec(&object).unwrap().as_slice()).is_err());
        }
    }

    /// Bounds allocation and prevents malformed-input errors from disclosing credential contents.
    #[test]
    fn rejects_oversized_or_malformed_input_without_echoing_it() {
        let bytes = vec![b'x'; MAX_CONFIGURATION_BYTES as usize + 1];
        assert!(read_configuration(bytes.as_slice()).is_err());
        let error = read_configuration(&b"secret-password-invalid-json"[..])
            .err()
            .unwrap();
        assert_eq!(error, "invalid local TUN configuration");
        assert!(read_configuration(&b""[..]).is_err());
    }

    /// Preserves escaped secrets and accepts ordinary IPv4 and IPv6 server literals.
    #[test]
    fn preserves_escaped_secrets_and_ip_literals() {
        for host in ["203.0.113.5", "2001:db8::5"] {
            let mut object = sample_value();
            object["host"] = host.into();
            object["password"] = "secret\nhttp:\n  listen: 0.0.0.0:80\"\\".into();
            let config =
                read_configuration(serde_json::to_vec(&object).unwrap().as_slice()).unwrap();
            assert_eq!(config.password, object["password"].as_str().unwrap());
        }
    }
}
