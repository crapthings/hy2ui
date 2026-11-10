//! Converts bounded SDK socket snapshots to indexed ownership records and revalidates cached candidates.
use super::{flow_index::{FlowKey, Record}, rule_index::RuleIndex};
use std::{ffi::CString, net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr}};

/// Mirrors the fixed C adapter layout without carrying native SDK structures across the boundary.
#[repr(C)]
#[derive(Clone)]
struct NativeOwner {
    start_seconds: u64, start_microseconds: u64, socket_identity: u64,
    pid: i32, descriptor: i32, source_port: u16, destination_port: u16,
    ipv6: u8, udp: u8, unconnected: u8, reserved: u8,
    source: [u8; 16], destination: [u8; 16],
}

// Checks the fixed-width adapter layout at compile time before using its FFI pointers.
const _: [(); 72] = [(); std::mem::size_of::<NativeOwner>()];

/// Retains the full process and socket identity needed to reject stale cached ownership.
#[derive(Clone)]
pub(super) struct Owner { native: NativeOwner, path: std::sync::Arc<CString> }

/// Accumulates one bounded snapshot and memoizes rule matching for repeated executable paths.
#[cfg(target_os = "macos")]
struct Collector<'a> {
    matcher: &'a RuleIndex,
    paths: std::collections::HashMap<String, (std::sync::Arc<CString>, bool)>,
    records: Vec<Record<Owner>>,
}

/// Converts native address bytes without conflating IPv4 with IPv6 mapped addresses.
fn address(bytes: [u8; 16], ipv6: bool, port: u16) -> SocketAddr {
    SocketAddr::new(if ipv6 { IpAddr::V6(Ipv6Addr::from(bytes)) }
        else { IpAddr::V4(Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3])) }, port)
}

/// Copies callback buffers while the C collector owns their lifetime and stops before unbounded allocation.
#[cfg(target_os = "macos")]
unsafe extern "C" fn emit(owner: *const NativeOwner, path: *const std::ffi::c_char, context: *mut std::ffi::c_void) -> i32 {
    // SAFETY: collect supplies the live Collector and the synchronous shim supplies non-null stack buffers.
    let (native, path, collector) = unsafe { (&*owner, std::ffi::CStr::from_ptr(path), &mut *(context as *mut Collector<'_>)) };
    if collector.records.len() >= 32_768 { return 0; }
    // Invalid UTF-8 cannot match UI rules, but its owner must remain in the ambiguity index.
    let decision = path.to_str().ok().map(|text| {
        collector.paths.entry(text.to_owned()).or_insert_with(|| (std::sync::Arc::new(path.to_owned()), collector.matcher.matches(text))).clone()
    }).unwrap_or_else(|| (std::sync::Arc::new(path.to_owned()), false));
    collector.records.push(Record {
        key: FlowKey { source: address(native.source, native.ipv6 != 0, native.source_port),
            destination: address(native.destination, native.ipv6 != 0, native.destination_port), udp: native.udp != 0 },
        owner: Owner { native: native.clone(), path: decision.0 }, direct: decision.1, unconnected: native.unconnected != 0,
    });
    1
}

/// Discards partial scans instead of publishing an incomplete owner table.
#[cfg(target_os = "macos")]
pub(super) fn collect(matcher: &RuleIndex) -> Option<Vec<Record<Owner>>> {
    let mut collector = Collector { matcher, paths: std::collections::HashMap::new(), records: Vec::new() };
    // SAFETY: callback and context remain live for the entire synchronous bounded scan.
    (unsafe { hy2_collect_flow_owners(emit, &mut collector as *mut Collector<'_> as *mut std::ffi::c_void) } == 1).then_some(collector.records)
}

/// Checks cached socket and executable identity using targeted SDK calls rather than a process enumeration.
#[cfg(target_os = "macos")]
pub(super) fn validate(owner: &Owner) -> bool {
    // SAFETY: both pointers refer to immutable owned buffers for the duration of this synchronous call.
    unsafe { hy2_validate_flow_owner(&owner.native, owner.path.as_ptr()) == 1 }
}

/// Leaves unsupported targets on the existing proxy path without guessing ownership.
#[cfg(not(target_os = "macos"))]
pub(super) fn collect(_: &RuleIndex) -> Option<Vec<Record<Owner>>> { None }

/// Rejects native process ownership on unsupported targets.
#[cfg(not(target_os = "macos"))]
pub(super) fn validate(_: &Owner) -> bool { false }

// Declares only the synchronous snapshot and validation shim entry points.
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn hy2_collect_flow_owners(callback: unsafe extern "C" fn(*const NativeOwner, *const std::ffi::c_char, *mut std::ffi::c_void) -> i32,
        context: *mut std::ffi::c_void) -> i32;
    fn hy2_validate_flow_owner(owner: *const NativeOwner, path: *const std::ffi::c_char) -> i32;
}
