//! Compiles literal IP rules and plans public TUN prefixes without DNS resolution or route mutation.
use std::{collections::HashMap, net::IpAddr};

/// Represents a canonical numeric network using the low bits for IPv4 and all bits for IPv6.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Network { value: u128, prefix: u8, bits: u8 }

/// Validates numeric prefixes and computes bounded recursive prefix subtraction.
impl Network {
    fn parse(input: &str) -> Result<Self, String> {
        let mut parts = input.split('/');
        let ip: IpAddr = parts.next().unwrap_or("").parse().map_err(|_| "invalid IP routing prefix")?;
        let bits = if ip.is_ipv6() { 128 } else { 32 };
        let prefix = match parts.next() {
            Some(p) if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) => p.parse::<u8>().map_err(|_| "invalid IP routing prefix")?,
            Some(_) => return Err("invalid IP routing prefix".into()), None => bits,
        };
        if prefix > bits || parts.next().is_some() { return Err("invalid IP routing prefix".into()); }
        let value = match ip { IpAddr::V4(v) => u32::from(v) as u128, IpAddr::V6(v) => u128::from(v) };
        Ok(Self { value: value & mask(bits, prefix), prefix, bits })
    }
    fn contains(self, other: Self) -> bool { self.bits == other.bits && self.prefix <= other.prefix && self.value == other.value & mask(self.bits, self.prefix) }
    fn cidr(self) -> String {
        let ip = if self.bits == 32 { IpAddr::from((self.value as u32).to_be_bytes()) } else { IpAddr::from(self.value.to_be_bytes()) };
        format!("{ip}/{}", self.prefix)
    }
    fn subtract(self, excluded: Self, output: &mut Vec<Self>) {
        if excluded.contains(self) { return; }
        if !self.contains(excluded) { output.push(self); return; }
        let child = Self { prefix: self.prefix + 1, ..self };
        child.subtract(excluded, output);
        Self { value: child.value | (1_u128 << (child.bits - child.prefix)), ..child }.subtract(excluded, output);
    }
}

/// Computes a family-width prefix mask without shifting by the integer width.
fn mask(bits: u8, prefix: u8) -> u128 { if prefix == 0 { 0 } else { u128::MAX << (bits - prefix) & (u128::MAX >> (128 - bits)) } }

/// Indexes explicit literal rules by prefix length for bounded longest-prefix lookup.
#[derive(Default)]
pub struct AddressIndex { rules: HashMap<(u8, u8, u128), bool> }

/// Validates direct/proxy entries once and matches addresses without scanning the rule list.
impl AddressIndex {
    pub fn new(rules: &[String]) -> Result<Self, String> {
        if rules.len() > 128 { return Err("too many IP routing rules".into()); }
        let mut index = Self::default();
        for rule in rules {
            let (action, target) = rule.split_once(',').ok_or("invalid IP routing rule")?;
            let direct = match action { "direct" => true, "proxy" => false, _ => return Err("invalid IP routing action".into()) };
            let network = Network::parse(target)?;
            if index.rules.insert((network.bits, network.prefix, network.value), direct).is_some() { return Err("duplicate IP routing rule".into()); }
        }
        Ok(index)
    }
    pub fn decision(&self, ip: IpAddr) -> Option<bool> {
        let (bits, value) = match ip { IpAddr::V4(v) => (32, u32::from(v) as u128), IpAddr::V6(v) => (128, u128::from(v)) };
        (0..=bits).rev().find_map(|prefix| self.rules.get(&(bits, prefix, value & mask(bits, prefix))).copied())
    }
}

/// Lists only local address ranges, keeping synthetic DNS and shared CGNAT space captured.
const LOCAL: &[&str] = &["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "255.255.255.255/32", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"];

/// Subtracts local prefixes from the split defaults without adding physical routes or replacing existing VPN routes.
pub fn capture_routes(bypass: bool) -> (Vec<String>, Vec<String>) {
    let mut routes: Vec<_> = ["0.0.0.0/1", "128.0.0.0/1", "::/1", "8000::/1"].iter().map(|s| Network::parse(s).unwrap()).collect();
    if bypass {
        for excluded in LOCAL { let mut next = Vec::new(); for route in routes { route.subtract(Network::parse(excluded).unwrap(), &mut next); } routes = next; }
    }
    (routes.iter().filter(|r| r.bits == 32).map(|r| r.cidr()).collect(), routes.iter().filter(|r| r.bits == 128).map(|r| r.cidr()).collect())
}

/// Verifies route coverage and indexed decisions entirely with synthetic addresses.
#[cfg(test)]
mod tests {
    use super::*;
    /// Leaves local addresses on original routes while retaining synthetic DNS and public dual-stack capture.
    #[test]
    fn local_routes_are_subtracted_without_synthetic_bypass() {
        let (v4,v6) = capture_routes(true); let routes: Vec<_> = v4.iter().chain(&v6).map(|s| Network::parse(s).unwrap()).collect();
        for target in ["10.1.2.3", "172.16.1.1", "192.168.50.1", "127.1.2.3", "169.254.1.2", "224.0.0.251", "255.255.255.255", "::1", "fd00::1", "fe80::1", "ff02::fb"] {
            let ip = Network::parse(target).unwrap(); assert!(!routes.iter().any(|r| r.contains(ip)), "{target}");
        }
        for target in ["198.18.4.166", "100.64.0.1", "1.1.1.1", "172.32.0.1", "2606:4700::1111", "::2"] {
            let ip = Network::parse(target).unwrap(); assert!(routes.iter().any(|r| r.contains(ip)), "{target}");
        }
        assert_eq!(capture_routes(false).0.len(),2); assert_eq!(capture_routes(false).1.len(),2);
    }
    /// Resolves narrower explicit proxy entries before broad direct prefixes and rejects malformed rules.
    #[test]
    fn longest_prefix_and_validation() {
        let index = AddressIndex::new(&["direct,203.0.113.0/24".into(), "proxy,203.0.113.8".into(), "direct,2001:db8::/32".into()]).unwrap();
        assert_eq!(index.decision("203.0.113.8".parse().unwrap()),Some(false));
        assert_eq!(index.decision("203.0.113.9".parse().unwrap()),Some(true));
        assert_eq!(index.decision("2001:db8::1".parse().unwrap()),Some(true));
        assert_eq!(index.decision("1.1.1.1".parse().unwrap()),None);
        for rule in ["direct,example.com", "invalid,1.1.1.1", "direct,::/129", "direct,1.1.1.1/24/1"] { assert!(AddressIndex::new(&[rule.into()]).is_err()); }
        assert!(AddressIndex::new(&["direct,1.1.1.1/24".into(), "proxy,1.1.1.0/24".into()]).is_err());
    }
}
